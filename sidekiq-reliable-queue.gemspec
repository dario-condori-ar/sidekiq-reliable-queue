Gem::Specification.new do |s|
  s.name        = 'sidekiq-reliable-queue'
  s.version     = '0.1'
  s.authors     = ['Quieroclientes']
  s.email       = 'quieroclientes.developers@publicar.com'
  s.license     = 'LGPL-3.0'
  s.homepage    = 'https://github.com/TEA-ebook/sidekiq-reliable-fetch'
  s.summary     = 'Reliable queue extension for Sidekiq'
  s.description = 'Redis reliable queue pattern implemented in Sidekiq'
  s.require_paths = ['lib']

  s.files = `git ls-files`.split($\)
  s.test_files  = []

  s.add_dependency 'sidekiq', '>= 5.0.0'
end
