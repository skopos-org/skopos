(() => {
  const navigation = document.getElementById("doc-language-navigation");
  const select = document.getElementById("doc-language");
  if (!navigation || !select) return;

  function mount() {
    const toolbar = document.querySelector(".top-search .search-settings");
    if (!toolbar) return;
    toolbar.insertBefore(navigation, toolbar.querySelector(".display-settings"));
    navigation.hidden = false;
  }

  select.addEventListener("change", async () => {
    select.disabled = true;
    const filename = location.pathname.split("/").pop() || "index.html";
    const home = new URL(select.value, location.href);
    const available = select.dataset.pages.split(" ").includes(filename);
    let destination = available ? new URL(filename, home) : home;
    destination.search = location.search;

    // Translated headings may have different anchors. Preserve only an anchor
    // present in the destination document; otherwise open the page at the top.
    if (available && location.hash) {
      try {
        const response = await fetch(destination, { signal: AbortSignal.timeout(3000) });
        if (response.ok) {
          const document = new DOMParser().parseFromString(await response.text(), "text/html");
          if (document.getElementById(decodeURIComponent(location.hash.slice(1)))) {
            destination.hash = location.hash;
          }
        } else if (response.status === 404) {
          destination = home;
          destination.search = location.search;
        }
      } catch {
        // Navigation still works offline and when the anchor cannot be checked.
      }
    }

    location.assign(destination.href);
  });

  // ExDoc replaces #main on internal navigation. Keep the original control and
  // reattach it to the new toolbar instead of creating additional listeners.
  window.addEventListener("exdoc:loaded", mount);
  mount();
})();
