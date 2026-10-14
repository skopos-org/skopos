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

language_options =
  locales
  |> Enum.sort()
  |> Enum.map_join("\n", fn {code, options} ->
    selected = if code == language, do: " selected", else: ""
    label = Plug.HTML.html_escape(Keyword.fetch!(options, :label))
    "<option value=\"../#{code}/overview.html\" lang=\"#{code}\"#{selected}>#{label}</option>"
  end)

language_navigation =
  if map_size(locales) > 1 do
    label = Plug.HTML.html_escape(Keyword.fetch!(locale, :language_navigation))
    filenames = Enum.map_join(pages, " ", &"#{&1}.html")

    """
    <nav id="doc-language-navigation" aria-label="#{label}" hidden>
      <select id="doc-language" aria-label="#{label}" data-pages="#{filenames} index.html license.html search.html">
        #{language_options}
      </select>
    </nav>
    <script src="assets/language-switcher.js"></script>
    """
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
  assets: %{"docs/assets" => "assets"},
  before_closing_head_tag: fn :html ->
    ~s(<link rel="stylesheet" href="assets/language-switcher.css">)
  end,
  before_closing_body_tag: fn :html -> language_navigation end
] ++ Keyword.fetch!(locale, :docs)
