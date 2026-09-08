# Homebrew formula template for `apple-docs` (stable channel).
#
# Url points at the registry (packages.techprimate.com), NOT at GitHub Release assets,
# so the formula has no dependency on the (possibly private) source repo.
class AppleDocs < Formula
  desc "CLI to explore Apple Developer Documentation"
  homepage "https://github.com/techprimate/apple-docs-cli"
  version "{{VERSION}}"

  depends_on :macos

  if Hardware::CPU.arm?
    url "https://packages.techprimate.com/apple-docs/bin/v{{VERSION}}/apple-docs-darwin-arm64"
    sha256 "{{SHA_DARWIN_ARM64}}"
  end

  if Hardware::CPU.intel?
    url "https://packages.techprimate.com/apple-docs/bin/v{{VERSION}}/apple-docs-darwin-amd64"
    sha256 "{{SHA_DARWIN_AMD64}}"
  end

  def install
    binary = Dir["apple-docs-*"].first
    bin.install binary => "apple-docs"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/apple-docs --version")
  end
end
