language = System.get_env("EXDOC_LANGUAGE", "en")

locales =
  for path <- Path.wildcard("docs/*/ex_doc.exs"), into: %{} do
    {options, _binding} = Code.eval_file(path)
    {Path.basename(Path.dirname(path)), options}
  end

locale =
  case Map.fetch(locales, language) do
    {:ok, options} -> options
    :error -> raise "No documentation locale configured for #{inspect(language)}"
  end

pages = ~w(overview installation configuration first-steps operations cli api contributing)

language_links =
  locales
  |> Enum.sort()
  |> Enum.map_join(" · ", fn {code, options} ->
    "<a href=\"../#{code}/index.html\" hreflang=\"#{code}\" lang=\"#{code}\">#{Keyword.fetch!(options, :label)}</a>"
  end)

language_navigation =
  if map_size(locales) > 1 do
    "<nav aria-label=\"#{Keyword.fetch!(locale, :language_navigation)}\">#{language_links}</nav>"
  else
    ""
  end

[
  main: "overview",
  language: language,
  output: "doc/#{language}",
  formatters: ["html"],
  canonical: "https://skopos-org.github.io/skopos/#{language}/",
  source_ref: "main",
  api_reference: false,
  filter_modules: fn _module, _metadata -> false end,
  extras:
    Enum.map(pages, &"docs/#{language}/#{&1}.md") ++
      [{:LICENSE, [filename: "license", title: Keyword.fetch!(locale, :license_title)]}],
  before_closing_footer_tag: fn :html -> language_navigation end
] ++ Keyword.fetch!(locale, :docs)
