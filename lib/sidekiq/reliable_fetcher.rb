module Sidekiq
  class ReliableFetcher < Sidekiq::BasicFetch
    WORKING_PREFIX = 'working'
    DEFAULT_QUEUE= 'common'
    DEFAULT_DEAD_AFTER = 60 * 60 * 24 # 24 hours
    DEFAULT_CLEANING_INTERVAL = 5000 # clean each N processed jobs
    IDLE_TIMEOUT = 5 # seconds

    def self.setup_reliable_fetch!(config)
      config.options[:fetch] = Sidekiq::ReliableFetcher
      config.on(:startup) do
        requeue_on_startup!(config.options[:queues])
      end
    end

    def initialize(options)
      @strictly_ordered_queues = !!options[:strict]
      @queues = options[:queues].map { |q| "queue:#{q}" }

      @unique_queues = @queues.uniq
      @queues_iterator = @queues.shuffle.cycle
      @queues_size  = @queues.size

      @nb_fetched_jobs = 0
      @idle_timeout= options[:idle_timeout] || IDLE_TIMEOUT
      @working_queue= WORKING_PREFIX + ":"+(options[:working_queue] || DEFAULT_QUEUE)
      @cleaning_interval = options[:cleaning_interval] || DEFAULT_CLEANING_INTERVAL
      @consider_dead_after = options[:consider_dead_after] || DEFAULT_DEAD_AFTER
    end

    def retrieve_work
      clean_working_queues! if @cleaning_interval != -1 && @nb_fetched_jobs >= @cleaning_interval

      @queues_size.times do
        queue = @queues_iterator.next
        work = Sidekiq.redis { |conn| conn.rpoplpush(queue, "#{queue}:#{@working_queue}") }

        if work
          @nb_fetched_jobs += 1
          return UnitOfWork.new(queue,work,@working_queue)
        end
      end

      # We didn't find a job in any of the configured queues. Let's sleep a bit
      # to avoid uselessly burning too much CPU
      sleep(@idle_timeout)

      nil
    end

    def self.idle_timeout
     Sidekiq.options[:idle_timeout]||IDLE_TIMEOUT
    end

    def self.working_queue
      WORKING_PREFIX + ":"+(Sidekiq.options[:working_queue] || DEFAULT_QUEUE)
    end

    def self.requeue_on_startup!(queues)
      Sidekiq.logger.debug { "Re-queueing working jobs" }
      counter = 0

      Sidekiq.redis do |conn|
        queues.uniq.each do |queue|
          while conn.rpoplpush("queue:#{queue}:#{self.working_queue}", "queue:#{queue}")
            counter += 1
          end
        end
      end
      Sidekiq.logger.debug { "Re-queued #{counter} jobs" }
    end

    # By leaving this as a class method, it can be pluggable and used by the Manager actor. Making it
    # an instance method will make it async to the Fetcher actor
    def self.bulk_requeue(inprogress, options)
      return if inprogress.empty?

      Sidekiq.logger.debug { "Re-queueing terminated jobs" }

      Sidekiq.redis do |conn|
        conn.pipelined do
          inprogress.each do |unit_of_work|
            conn.lpush("#{unit_of_work.queue}", unit_of_work.message)
            conn.lrem("#{unit_of_work.queue}:#{self.working_queue}", 1, unit_of_work.message)
          end
        end
      end

      Sidekiq.logger.info("Pushed #{inprogress.size} messages back to Redis")
    rescue => ex
      Sidekiq.logger.warn("Failed to requeue #{inprogress.size} jobs: #{ex.message}")
    end

    UnitOfWork = Struct.new(:queue, :job, :working_queue) do
      def acknowledge
        # NOTE LREM is O(n), so depending on the type of jobs and their average
        # duration, another data structure might be more suited.
        # But as there should not be too much jobs in this queue in the same time,
        # it's probably ok.
        Sidekiq.redis { |conn| conn.lrem("queue:#{queue_name}:#{working_queue}", 1, job) }
      end

      def queue_name
        queue.sub(/.*queue:/, ''.freeze)
      end

      def requeue
        Sidekiq.redis do |conn|
          conn.pipelined do
            conn.lpush("queue:#{queue_name}", job)
            conn.lrem("queue:#{queue_name}:#{working_queue}", 1, job)
          end
        end
      end
    end

    private

    # Detect "old" jobs and requeue them because the worker they were assigned
    # to probably failed miserably.
    # NOTE Potential problem here if a specific job always make a worker
    # really fail.
    def clean_working_queues!
      Sidekiq.logger.debug "Cleaning working queues"

      @unique_queues.each do |queue|
        clean_working_queue!(queue)
      end

      @nb_fetched_jobs = 0
    end

    def clean_working_queue!(queue)
      Sidekiq.redis do |conn|
        working_jobs = conn.lrange("#{queue}:#{@working_queue}", 0, -1)
        working_jobs.each do |job|
          enqueued_at = Sidekiq.load_json(job)['enqueued_at'].to_i
          job_duration = Time.now.to_i - enqueued_at

          next if job_duration < @consider_dead_after

          Sidekiq.logger.info "Requeued a dead job from #{queue}:#{@working_queue}"

          conn.lpush("#{queue}", job)
          conn.lrem("#{queue}:#{@working_queue}", 1, job)
        end
      end
    end
  end
end
