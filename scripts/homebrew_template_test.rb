require 'tmpdir'
require 'open3'
require 'yaml'
require 'formula'
require 'formulary'
require 'simulate_system'
require_relative 'render_homebrew'

def assert_equal(expected, actual)
  raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

def assert_install_generates_completions(formula, directory)
  # -- Arrange --
  prefix = Pathname(directory) / 'prefix'
  formula.define_singleton_method(:prefix) { prefix }
  source = Pathname(directory) / 'apple-docs-test'
  source.write <<~SH
    #!/bin/sh
    test "$1" = '--generate-completion-script' || exit 1
    if [ "$TELEMETRY_DISABLED" != 'true' ]; then
      printf 'unexpected telemetry output\\n'
    fi
    printf 'completion for %s\\n' "$2"
  SH
  source.chmod 0644

  # -- Act --
  with_env('TELEMETRY_DISABLED' => nil) do
    Dir.chdir(directory) { formula.install }
  end

  # -- Assert --
  raise 'Installed binary is not executable' unless (formula.bin / 'apple-docs').executable?

  assert_equal("completion for bash\n", (formula.bash_completion / 'apple-docs').read)
  assert_equal("completion for zsh\n", (formula.zsh_completion / '_apple-docs').read)
  assert_equal("completion for fish\n", (formula.fish_completion / 'apple-docs.fish').read)
end

def assert_rejected
  yield
rescue ArgumentError
  nil
else
  raise 'Expected invalid template input to be rejected'
end

root = File.expand_path('..', __dir__)
checksums = {
  'SHA_DARWIN_AMD64' => '1' * 64,
  'SHA_DARWIN_ARM64' => '2' * 64,
  'SHA_LINUX_AMD64' => '3' * 64,
  'SHA_LINUX_ARM64' => '4' * 64
}

Dir.mktmpdir('publisher-homebrew-test') do |directory|
  Dir[File.join(root, 'packages/*/manifest.yaml')].each do |manifest_path|
    manifest = YAML.safe_load_file(manifest_path)
    name = manifest.fetch('homebrew_formula')
    template_path = File.join(root, 'templates', "#{name}.rb")
    template = File.read(template_path)

    %w[0.0.3 0.0.4 0.0.5 0.0.6].each do |version|
      values = checksums.merge('VERSION' => version)
      rendered = render_homebrew(template, values)
      raise 'Unresolved template placeholder' if rendered.match?(/\{\{.*?\}\}/)

      output_path = Pathname(directory) / version / 'Formula' / "#{name}.rb"
      output_path.dirname.mkpath
      output, status = Open3.capture2e(values, RbConfig.ruby, File.join(__dir__, 'render_homebrew.rb'), template_path,
                                       output_path)
      raise "Renderer CLI failed: #{output}" unless status.success?

      assert_equal(rendered, File.read(output_path))

      output, status = Open3.capture2e(HOMEBREW_BREW_FILE.to_s, 'style', output_path.to_s)
      raise "Rendered formula style failed: #{output}" unless status.success?

      manifest.fetch('platforms').each do |platform|
        system, architecture = platform.split('-')
        os = system == 'darwin' ? :macos : :linux
        arch = architecture == 'arm64' ? :arm : :intel
        Homebrew::SimulateSystem.with(os: os, arch: arch) do
          path = Pathname(directory) / version / platform / "#{name}.rb"
          formula = Formulary.from_contents(name, path, rendered, tap: Tap.fetch('techprimate/publisher'))
          expected_revision = name == 'apple-docs' ? { '0.0.4' => 1, '0.0.5' => 2 }.fetch(version, 0) : 0
          assert_equal(version, formula.version.to_s)
          assert_equal(expected_revision, formula.revision)
          assert_equal(
            "https://packages.techprimate.com/#{manifest.fetch('package')}/bin/v#{version}/#{manifest.fetch('binary')}-#{platform}",
            formula.stable.url
          )
          assert_equal(checksums.fetch("SHA_#{platform.upcase.tr('-', '_')}"), formula.stable.checksum.to_s)
          raise 'Missing formula test' unless formula.test_defined?

          if name == 'apple-docs' && version == '0.0.5'
            Dir.mktmpdir('install-', directory) do |install_directory|
              assert_install_generates_completions(formula, install_directory)
            end
          end
        end
      end
    end
    puts "PASS: #{name} rendering, Homebrew style, platform selection, and version-scoped revisions"
  end
end

values = checksums.merge('VERSION' => '0.0.4')
assert_rejected { render_homebrew("version '{{UNKNOWN}}'", values) }
assert_rejected { render_homebrew("version '{{VERSION}}'", values.merge('VERSION' => "0.0.4'\nraise 'injected")) }
assert_rejected { render_homebrew("sha256 '{{SHA_DARWIN_ARM64}}'", values.merge('SHA_DARWIN_ARM64' => 'invalid')) }
assert_rejected do
  render_homebrew("sha256 '{{SHA_DARWIN_ARM64}}'", values.reject do |key, _|
    key == 'SHA_DARWIN_ARM64'
  end)
end
assert_rejected { render_homebrew('class Broken < Formula', values) }
puts 'PASS: unknown placeholders, unsafe versions, missing/invalid checksums, and Ruby syntax errors are rejected'
