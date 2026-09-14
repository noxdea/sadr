# frozen_string_literal: true

require_relative "lib/sadr/version"

Gem::Specification.new do |spec|
  spec.name = "sadr"
  spec.version = Sadr::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]
  spec.summary = "A pure Ruby Language Server Protocol client"
  spec.homepage = "https://github.com/noxdea/sadr"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir.chdir(__dir__) do
    Dir["{lib,sig,docs}/**/*", "README.md", "CHANGELOG.md", "LICENSE.txt"].select { |path| File.file?(path) }
  end
  spec.require_paths = ["lib"]
end
