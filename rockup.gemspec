$: << 'lib'
require 'rockup'
Gem::Specification.new do |spec|
  spec.name = 'rockup'
  spec.version = Rockup::Version
  spec.author = 'Oleg A. Khlybov'
  spec.email = 'fougas@mail.ru'
  spec.homepage = 'https://bitbucket.org/fougas/rockup'
  spec.summary = 'Cloud-friendly incremental file backup system'
  spec.files = Dir.glob ['lib/**/*.rb']
  spec.executables = ['rockup']
  spec.required_ruby_version = '>= 2.4'
  spec.licenses = ['BSD-3-Clause']
  spec.description = <<-EOF
    Rockup is a file backup system designed to be cloud-friendly.
    Rockup features:
      - 100% Ruby engine and command-line utility
      - Full and incremental backups
      - Backup data compression
      - Backup data encryption
      - More to come
  EOF
end