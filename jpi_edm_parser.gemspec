# frozen_string_literal: true

require_relative 'lib/jpi_edm_parser/version'

Gem::Specification.new do |spec|
  spec.name          = 'jpi_edm_parser'
  spec.version       = JpiEdmParser::VERSION
  spec.authors       = ['OpenEngineData.org Contributors']
  spec.email         = ['']
  
  spec.summary       = 'Parse JPI EDM engine monitor data files'
  spec.description   = 'A Ruby library for parsing JPI EDM (Engine Data Management) ' \
                       'engine monitor data files used in general aviation aircraft. ' \
                       'Supports EDM 700/730/800/830/900/930/960 series monitors.'
  spec.homepage      = 'https://github.com/openenginedata/jpi_edm_parser'
  spec.license       = 'MIT'
  
  spec.required_ruby_version = '>= 3.0.0'
  
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  
  # Specify which files should be added to the gem when it is released.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) ||
        f.match(%r{\A(?:(?:bin|test|spec|features)/|\.(?:git|circleci)|appveyor)})
    end
  end
  
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']
  
  # Development dependencies
  spec.add_development_dependency 'bundler'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'rubocop', '~> 1.0'
end
