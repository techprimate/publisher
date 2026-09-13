require 'ripper'

# Only substitute literal release metadata, never Ruby source supplied by a release.
def render_homebrew(template, values)
  rendered = template.gsub(/\{\{(.*?)\}\}/) do
    key = Regexp.last_match(1)
    pattern = case key
              when 'VERSION'
                /\A[0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z.-]+)?\z/
              when /\ASHA_(?:DARWIN|LINUX)_(?:AMD64|ARM64)\z/
                /\A[0-9a-fA-F]{64}\z/
              else
                raise ArgumentError, "Unknown Homebrew template placeholder: #{key}"
              end
    value = values[key]
    raise ArgumentError, "Missing or invalid Homebrew template value: #{key}" unless value && pattern.match?(value)

    value
  end
  raise ArgumentError, 'Rendered Homebrew formula has invalid Ruby syntax' unless Ripper.sexp(rendered)

  rendered
end

if $PROGRAM_NAME == __FILE__
  template_path, output_path = ARGV
  rendered = render_homebrew(File.read(template_path), ENV)
  File.write(output_path, rendered)
end
