class AppleDocs < Formula
  desc 'CLI to explore Apple Developer Documentation'
  homepage 'https://github.com/techprimate/apple-docs-cli'
  version '{{VERSION}}'
  license 'FSL-1.1-MIT'
  revision 1 if version.to_s == '0.0.4'

  on_macos do
    depends_on macos: :ventura

    on_arm do
      url 'https://packages.techprimate.com/apple-docs/bin/v{{VERSION}}/apple-docs-darwin-arm64'
      sha256 '{{SHA_DARWIN_ARM64}}'
    end
    on_intel do
      url 'https://packages.techprimate.com/apple-docs/bin/v{{VERSION}}/apple-docs-darwin-amd64'
      sha256 '{{SHA_DARWIN_AMD64}}'
    end
  end

  on_linux do
    on_arm do
      url 'https://packages.techprimate.com/apple-docs/bin/v{{VERSION}}/apple-docs-linux-arm64'
      sha256 '{{SHA_LINUX_ARM64}}'
    end
    on_intel do
      url 'https://packages.techprimate.com/apple-docs/bin/v{{VERSION}}/apple-docs-linux-amd64'
      sha256 '{{SHA_LINUX_AMD64}}'
    end
  end

  def install
    binary = Dir['apple-docs-*'].first
    bin.install binary => 'apple-docs'
    generate_completions_from_executable(bin / 'apple-docs', '--generate-completion-script')
  end

  test do
    ENV['TELEMETRY_DISABLED'] = 'true'
    assert_match version.to_s, shell_output("#{bin}/apple-docs --version")
    assert_match "apple-docs\t", shell_output("#{bin}/apple-docs agent skills list")
    assert_match 'name: apple-docs', shell_output("#{bin}/apple-docs agent skills get apple-docs")
    assert_path_exists bash_completion / 'apple-docs'
    assert_path_exists zsh_completion / '_apple-docs'
    assert_path_exists fish_completion / 'apple-docs.fish'
  end
end
