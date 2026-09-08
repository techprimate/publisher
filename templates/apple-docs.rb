# Homebrew formula template for `apple-docs` (stable channel).
# Moved here from techprimate/apple-docs per the publisher design migration. Rendered by
# .github/workflows/_homebrew.yml and PR'd to techprimate/homebrew-tap.
#
# url points at the registry (packages.techprimate.app), NOT at GitHub Release assets,
# so the formula has no dependency on the (possibly private) source repo.
class apple-docs < Formula
  desc "CLI to explore Apple Developer Documentation"
  homepage "https://github.com/techprimate/apple-docs"
  version "{{VERSION}}"

  on_macos do
    on_arm do
      url "https://packages.techprimate.app/apple-docs/bin/v{{VERSION}}/apple-docs-darwin-arm64"
      sha256 "{{SHA_DARWIN_ARM64}}"
    end
    on_intel do
      url "https://packages.techprimate.app/apple-docs/bin/v{{VERSION}}/apple-docs-darwin-amd64"
      sha256 "{{SHA_DARWIN_AMD64}}"
    end
  end

  on_linux do
    on_arm do
      url "https://packages.techprimate.app/apple-docs/bin/v{{VERSION}}/apple-docs-linux-arm64"
      sha256 "{{SHA_LINUX_ARM64}}"
    end
    on_intel do
      url "https://packages.techprimate.app/apple-docs/bin/v{{VERSION}}/apple-docs-linux-amd64"
      sha256 "{{SHA_LINUX_AMD64}}"
    end
  end

  def install
    binary = Dir["apple-docs-*"].first
    bin.install binary => "apple-docs"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/apple-docs --version")
  end
end
