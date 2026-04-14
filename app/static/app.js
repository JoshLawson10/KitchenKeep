/**
 * KitchenKeep — Frontend JavaScript
 *
 * Module pattern under window.RecipeApp to avoid polluting global scope.
 * Each HTML page calls the appropriate init function via data-page attribute.
 *
 * Pages:
 *   index  → initIndex()
 *   recipe → initRecipe()
 *   edit   → initEdit()
 */

(function () {
  "use strict";

  // ------------------------------------------------------------------
  // Namespace
  // ------------------------------------------------------------------
  window.RecipeApp = window.RecipeApp || {};
  const App = window.RecipeApp;

  /** Base API prefix */
  const API = "/api";

  // ------------------------------------------------------------------
  // Utility: parseFraction
  // ------------------------------------------------------------------
  /**
   * Parse a string that may contain a fraction, mixed number, or decimal.
   * Examples: "1/2" → 0.5, "2 1/4" → 2.25, "3" → 3, "2.5" → 2.5
   * Returns NaN if unparseable.
   * @param {string} str
   * @returns {number}
   */
  App.parseFraction = function (str) {
    if (typeof str !== "string") return NaN;
    str = str.trim();
    // Mixed number: "2 1/4"
    const mixed = str.match(/^(\d+)\s+(\d+)\s*\/\s*(\d+)$/);
    if (mixed) {
      return parseInt(mixed[1]) + parseInt(mixed[2]) / parseInt(mixed[3]);
    }
    // Simple fraction: "3/4"
    const frac = str.match(/^(\d+)\s*\/\s*(\d+)$/);
    if (frac) {
      return parseInt(frac[1]) / parseInt(frac[2]);
    }
    // Plain number or decimal
    const n = parseFloat(str);
    return isNaN(n) ? NaN : n;
  };

  // ------------------------------------------------------------------
  // Utility: toFriendlyFraction
  // ------------------------------------------------------------------
  /**
   * Convert a float to a human-readable fraction or decimal string.
   * Common fractions are rendered symbolically; others as 2dp decimals.
   * @param {number} val
   * @returns {string}
   */
  App.toFriendlyFraction = function (val) {
    if (isNaN(val)) return "?";
    const whole = Math.floor(val);
    const rem = val - whole;
    const FRACS = [
      [1 / 8, "⅛"], [1 / 4, "¼"], [1 / 3, "⅓"],
      [3 / 8, "⅜"], [1 / 2, "½"], [5 / 8, "⅝"],
      [2 / 3, "⅔"], [3 / 4, "¾"], [7 / 8, "⅞"],
    ];
    for (const [frac, sym] of FRACS) {
      if (Math.abs(rem - frac) < 0.01) {
        return whole > 0 ? `${whole} ${sym}` : sym;
      }
    }
    if (rem < 0.01) return String(whole);
    return (whole > 0 ? `${whole} ` : "") + rem.toFixed(2).replace(/^0\./, ".");
  };

  // ------------------------------------------------------------------
  // Utility: debounce
  // ------------------------------------------------------------------
  /**
   * Return a debounced version of fn that fires after ms milliseconds
   * of silence.
   * @param {Function} fn
   * @param {number} ms
   * @returns {Function}
   */
  App.debounce = function (fn, ms) {
    let timer;
    return function (...args) {
      clearTimeout(timer);
      timer = setTimeout(() => fn.apply(this, args), ms);
    };
  };

  // ------------------------------------------------------------------
  // Utility: showToast
  // ------------------------------------------------------------------
  /**
   * Display a brief notification toast in the top-right corner.
   * @param {string} message
   * @param {'info'|'success'|'error'} type
   */
  App.showToast = function (message, type = "info") {
    let container = document.getElementById("toast-container");
    if (!container) {
      container = document.createElement("div");
      container.id = "toast-container";
      document.body.appendChild(container);
    }
    const toast = document.createElement("div");
    toast.className = `toast ${type}`;
    toast.textContent = message;
    container.appendChild(toast);
    setTimeout(() => {
      toast.style.opacity = "0";
      toast.style.transition = "opacity 0.3s";
      setTimeout(() => toast.remove(), 350);
    }, 3000);
  };

  // ------------------------------------------------------------------
  // Utility: safe DOM text setter (never innerHTML with user content)
  // ------------------------------------------------------------------
  function setTextSafe(el, text) {
    if (el) el.textContent = text ?? "";
  }

  // ------------------------------------------------------------------
  // Utility: build tag pill element
  // ------------------------------------------------------------------
  function makePill(tag) {
    const span = document.createElement("span");
    span.className = "tag-pill";
    span.textContent = tag;
    return span;
  }

  // ------------------------------------------------------------------
  // Utility: format time
  // ------------------------------------------------------------------
  function formatTime(mins) {
    if (!mins) return null;
    if (mins < 60) return `${mins}m`;
    const h = Math.floor(mins / 60);
    const m = mins % 60;
    return m > 0 ? `${h}h ${m}m` : `${h}h`;
  }

  // ------------------------------------------------------------------
  // PAGE: Index (recipe list)
  // ------------------------------------------------------------------
  App.initIndex = function () {
    const grid = document.getElementById("recipe-grid");
    const searchInput = document.getElementById("search-input");
    const tagSelect = document.getElementById("tag-filter");
    const urlModal = document.getElementById("url-modal");
    const modalOverlay = document.getElementById("modal-overlay");
    const urlInput = document.getElementById("url-input");
    const scrapeBtn = document.getElementById("scrape-btn");
    const scrapeStatus = document.getElementById("scrape-status");
    const scrapeStatusText = document.getElementById("scrape-status-text");
    const scrapeError = document.getElementById("scrape-error");
    const addBtn = document.getElementById("add-recipe-btn");
    const pasteBtn = document.getElementById("paste-url-btn");
    const modalCloseBtn = document.getElementById("modal-close-btn");

    let currentQuery = "";
    let currentTag = "";

    // Load tags for dropdown
    async function loadTags() {
      try {
        const res = await fetch(`${API}/tags`);
        if (!res.ok) return;
        const tags = await res.json();
        tags.forEach((tag) => {
          const opt = document.createElement("option");
          opt.value = tag;
          opt.textContent = tag;
          tagSelect.appendChild(opt);
        });
      } catch (_) {
        // Tags dropdown failure is non-critical
      }
    }

    // Fetch and render recipe cards
    async function loadRecipes() {
      const params = new URLSearchParams();
      if (currentQuery) params.set("q", currentQuery);
      if (currentTag) params.set("tag", currentTag);
      const url = `${API}/recipes${params.toString() ? "?" + params : ""}`;

      try {
        const res = await fetch(url);
        if (!res.ok) throw new Error("Server error");
        const recipes = await res.json();
        renderGrid(recipes);
      } catch (err) {
        grid.innerHTML = "";
        const msg = document.createElement("p");
        msg.className = "text-muted";
        msg.textContent = "Unable to load recipes. Please try refreshing.";
        grid.appendChild(msg);
      }
    }

    // Render the card grid
    function renderGrid(recipes) {
      grid.innerHTML = "";

      if (recipes.length === 0) {
        const empty = document.getElementById("empty-state");
        if (empty) empty.style.display = "flex";
        return;
      }

      const empty = document.getElementById("empty-state");
      if (empty) empty.style.display = "none";

      recipes.forEach((r) => {
        const a = document.createElement("a");
        a.href = `recipe.html?id=${r.id}`;
        a.className = "recipe-card";
        a.setAttribute("aria-label", r.title);

        // Image or placeholder
        if (r.image_url) {
          const img = document.createElement("img");
          img.className = "recipe-card__image";
          img.src = r.image_url;
          img.alt = r.title;
          img.loading = "lazy";
          img.onerror = function () {
            // Swap failed image for placeholder
            const ph = makePlaceholder();
            this.parentNode.replaceChild(ph, this);
          };
          a.appendChild(img);
        } else {
          a.appendChild(makePlaceholder());
        }

        // Card body
        const body = document.createElement("div");
        body.className = "recipe-card__body";

        const title = document.createElement("div");
        title.className = "recipe-card__title";
        title.textContent = r.title;
        body.appendChild(title);

        if (r.description) {
          const desc = document.createElement("div");
          desc.className = "recipe-card__desc";
          // Truncate to ~100 chars safely
          const text = r.description.length > 100
            ? r.description.slice(0, 97) + "…"
            : r.description;
          desc.textContent = text;
          body.appendChild(desc);
        }

        // Tags
        if (r.tags && r.tags.length > 0) {
          const tagsDiv = document.createElement("div");
          tagsDiv.className = "recipe-card__tags";
          r.tags.slice(0, 4).forEach((t) => tagsDiv.appendChild(makePill(t)));
          body.appendChild(tagsDiv);
        }

        // Meta: time
        const meta = document.createElement("div");
        meta.className = "recipe-card__meta";

        const prepTime = formatTime(r.prep_time_mins);
        const cookTime = formatTime(r.cook_time_mins);

        if (prepTime) {
          const item = document.createElement("span");
          item.className = "recipe-card__meta-item";
          item.innerHTML = `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="6.5"/><path d="M8 4.5v3.75l2.5 1.5"/></svg>`;
          const t = document.createElement("span");
          t.textContent = `Prep ${prepTime}`;
          item.appendChild(t);
          meta.appendChild(item);
        }
        if (cookTime) {
          const item = document.createElement("span");
          item.className = "recipe-card__meta-item";
          item.innerHTML = `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="2" y="7" width="12" height="7" rx="1"/><path d="M5 7V5a3 3 0 016 0v2"/></svg>`;
          const t = document.createElement("span");
          t.textContent = `Cook ${cookTime}`;
          item.appendChild(t);
          meta.appendChild(item);
        }
        body.appendChild(meta);
        a.appendChild(body);
        grid.appendChild(a);
      });
    }

    function makePlaceholder() {
      const div = document.createElement("div");
      div.className = "recipe-card__image-placeholder";
      div.textContent = "🍽";
      return div;
    }

    // Search handling (debounced)
    searchInput.addEventListener(
      "input",
      App.debounce(function () {
        currentQuery = this.value.trim();
        loadRecipes();
      }, 300)
    );

    // Tag filter
    tagSelect.addEventListener("change", function () {
      currentTag = this.value;
      loadRecipes();
    });

    // Modal open/close
    function openModal() {
      modalOverlay.classList.add("open");
      urlInput.value = "";
      scrapeStatus.classList.remove("visible");
      scrapeError.classList.remove("visible");
      urlInput.focus();
    }
    function closeModal() {
      modalOverlay.classList.remove("open");
    }
    pasteBtn.addEventListener("click", openModal);
    modalCloseBtn.addEventListener("click", closeModal);
    modalOverlay.addEventListener("click", function (e) {
      if (e.target === modalOverlay) closeModal();
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") closeModal();
    });

    // Scrape URL
    scrapeBtn.addEventListener("click", async function () {
      const url = urlInput.value.trim();
      if (!url) {
        urlInput.focus();
        return;
      }

      // Disable UI
      scrapeBtn.disabled = true;
      urlInput.disabled = true;
      scrapeStatus.classList.add("visible");
      scrapeError.classList.remove("visible");
      setTextSafe(scrapeStatusText, "Fetching page…");

      // After short delay, update status text
      const statusTimer = setTimeout(() => {
        setTextSafe(scrapeStatusText, "Extracting recipe with AI…");
      }, 3000);

      try {
        const res = await fetch(`${API}/scrape`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ url }),
        });
        clearTimeout(statusTimer);
        const data = await res.json();

        if (data.error) {
          scrapeStatus.classList.remove("visible");
          scrapeError.classList.add("visible");
          const msgs = {
            fetch_failed: `Could not fetch the page: ${data.message || "network error"}`,
            parse_failed: "AI couldn't extract the recipe. You can fill it in manually.",
            ollama_unavailable: "AI model is not running. Try again in a moment.",
            extraction_failed: "Extraction failed. Please fill in manually.",
          };
          scrapeError.textContent = msgs[data.error] || "Something went wrong. Please try again.";
        } else {
          // Success — store in sessionStorage and navigate to edit form
          sessionStorage.setItem("scraped_recipe", JSON.stringify(data));
          window.location.href = "edit.html";
        }
      } catch (err) {
        clearTimeout(statusTimer);
        scrapeStatus.classList.remove("visible");
        scrapeError.classList.add("visible");
        scrapeError.textContent = "Network error. Check your connection and try again.";
      } finally {
        scrapeBtn.disabled = false;
        urlInput.disabled = false;
      }
    });

    // Allow scraping on Enter key
    urlInput.addEventListener("keydown", function (e) {
      if (e.key === "Enter") scrapeBtn.click();
    });

    // Initial load
    loadTags();
    loadRecipes();
  };

  // ------------------------------------------------------------------
  // PAGE: Recipe detail
  // ------------------------------------------------------------------
  App.initRecipe = function () {
    const params = new URLSearchParams(window.location.search);
    const recipeId = params.get("id");

    if (!recipeId) {
      window.location.href = "index.html";
      return;
    }

    let baseServings = null;
    let currentServings = null;
    let baseIngredients = [];

    const titleEl      = document.getElementById("recipe-title");
    const descEl       = document.getElementById("recipe-desc");
    const tagsEl       = document.getElementById("recipe-tags");
    const prepEl       = document.getElementById("recipe-prep");
    const cookEl       = document.getElementById("recipe-cook");
    const servingsDisp = document.getElementById("servings-display");
    const ingList      = document.getElementById("ingredient-list");
    const stepsList    = document.getElementById("steps-list");
    const notesEl      = document.getElementById("recipe-notes");
    const notesText    = document.getElementById("recipe-notes-text");
    const sourceEl     = document.getElementById("recipe-source");
    const sourceLink   = document.getElementById("source-link");
    const heroImage    = document.getElementById("hero-image");
    const heroPlaceholder = document.getElementById("hero-placeholder");
    const editBtn      = document.getElementById("edit-btn");
    const deleteBtn    = document.getElementById("delete-btn");
    const minusBtn     = document.getElementById("servings-minus");
    const plusBtn      = document.getElementById("servings-plus");

    async function loadRecipe() {
      try {
        const res = await fetch(`${API}/recipes/${recipeId}`);
        if (res.status === 404) {
          window.location.href = "index.html";
          return;
        }
        if (!res.ok) throw new Error("Server error");
        const recipe = await res.json();
        renderRecipe(recipe);
      } catch (err) {
        App.showToast("Failed to load recipe.", "error");
      }
    }

    function renderRecipe(r) {
      document.title = `${r.title} — KitchenKeep`;
      setTextSafe(titleEl, r.title);
      if (r.description) {
        setTextSafe(descEl, r.description);
      } else {
        if (descEl) descEl.style.display = "none";
      }

      // Image
      if (r.image_url && heroImage) {
        heroImage.src = r.image_url;
        heroImage.alt = r.title;
        heroImage.style.display = "block";
        if (heroPlaceholder) heroPlaceholder.style.display = "none";
        heroImage.onerror = function () {
          this.style.display = "none";
          if (heroPlaceholder) heroPlaceholder.style.display = "flex";
        };
      }

      // Tags
      if (tagsEl && r.tags && r.tags.length > 0) {
        r.tags.forEach((t) => tagsEl.appendChild(makePill(t)));
      }

      // Times
      if (prepEl) setTextSafe(prepEl, r.prep_time_mins ? formatTime(r.prep_time_mins) : "—");
      if (cookEl) setTextSafe(cookEl, r.cook_time_mins ? formatTime(r.cook_time_mins) : "—");

      // Servings scaler
      baseServings = r.servings || 1;
      currentServings = baseServings;
      if (servingsDisp) setTextSafe(servingsDisp, currentServings);

      // Ingredients (store base for scaling)
      baseIngredients = r.ingredients || [];
      renderIngredients(1); // scale factor = 1

      // Steps
      if (stepsList) {
        (r.steps || []).forEach((step, i) => {
          const li = document.createElement("li");
          li.className = "step-item";
          const num = document.createElement("div");
          num.className = "step-number";
          num.textContent = i + 1;
          const text = document.createElement("div");
          text.className = "step-text";
          text.textContent = step;
          li.appendChild(num);
          li.appendChild(text);
          stepsList.appendChild(li);
        });
      }

      // Notes
      if (r.notes && notesEl && notesText) {
        notesEl.style.display = "block";
        setTextSafe(notesText, r.notes);
      }

      // Source URL
      if (r.source_url && sourceEl && sourceLink) {
        sourceEl.style.display = "block";
        sourceLink.href = r.source_url;
        sourceLink.textContent = r.source_url;
      }

      // Edit / delete buttons
      if (editBtn) editBtn.href = `edit.html?id=${r.id}`;
    }

    function renderIngredients(scale) {
      if (!ingList) return;
      ingList.innerHTML = "";
      
      baseIngredients.forEach((section) => {
        // Section Header
        if (section.section_name) {
          const hEl = document.createElement("li");
          hEl.className = "ingredient-heading";
          hEl.textContent = section.section_name;
          ingList.appendChild(hEl);
        }

        // List inside section
        (section.ingredients || []).forEach(ing => {
          const li = document.createElement("li");
          li.className = "ingredient-item";

          const amountEl = document.createElement("span");
          amountEl.className = "ingredient-amount";

          const parsed = App.parseFraction(ing.amount);
          if (!isNaN(parsed)) {
            amountEl.textContent = App.toFriendlyFraction(parsed * scale);
          } else {
            amountEl.textContent = ing.amount || "";
          }
          li.appendChild(amountEl);

          if (ing.unit) {
            const unitEl = document.createElement("span");
            unitEl.className = "ingredient-unit";
            unitEl.textContent = ing.unit;
            li.appendChild(unitEl);
          }

          const nameEl = document.createElement("span");
          nameEl.textContent = ing.name;
          li.appendChild(nameEl);

          if (ing.note) {
            const noteEl = document.createElement("span");
            noteEl.className = "ingredient-note";
            noteEl.textContent = `(${ing.note})`;
            li.appendChild(noteEl);
          }

          ingList.appendChild(li);
        });
      });
    }

    // Servings scaler events
    if (minusBtn) {
      minusBtn.addEventListener("click", function () {
        if (currentServings > 1) {
          currentServings--;
          if (servingsDisp) setTextSafe(servingsDisp, currentServings);
          renderIngredients(currentServings / baseServings);
        }
      });
    }
    if (plusBtn) {
      plusBtn.addEventListener("click", function () {
        currentServings++;
        if (servingsDisp) setTextSafe(servingsDisp, currentServings);
        renderIngredients(currentServings / baseServings);
      });
    }

    // Delete
    if (deleteBtn) {
      deleteBtn.addEventListener("click", async function () {
        if (!confirm("Delete this recipe? This cannot be undone.")) return;
        try {
          const res = await fetch(`${API}/recipes/${recipeId}`, { method: "DELETE" });
          if (res.ok) {
            window.location.href = "index.html";
          } else {
            App.showToast("Failed to delete recipe.", "error");
          }
        } catch (_) {
          App.showToast("Network error. Please try again.", "error");
        }
      });
    }

    loadRecipe();
  };

  // ------------------------------------------------------------------
  // PAGE: Edit / Add recipe
  // ------------------------------------------------------------------
  App.initEdit = function () {
    const urlParams = new URLSearchParams(window.location.search);
    const recipeId = urlParams.get("id");
    const isEdit = !!recipeId;

    const formTitle   = document.getElementById("form-title");
    const form        = document.getElementById("recipe-form");
    const saveBtn     = document.getElementById("save-btn");
    const cancelBtn   = document.getElementById("cancel-btn");

    // Form fields
    const fTitle      = document.getElementById("f-title");
    const fDesc       = document.getElementById("f-desc");
    const fSourceUrl  = document.getElementById("f-source-url");
    const fImageUrl   = document.getElementById("f-image-url");
    const fServings   = document.getElementById("f-servings");
    const fPrep       = document.getElementById("f-prep");
    const fCook       = document.getElementById("f-cook");
    const fTags       = document.getElementById("f-tags");
    const fTagsPreview = document.getElementById("f-tags-preview");
    const fNotes      = document.getElementById("f-notes");
    const ingList     = document.getElementById("ing-list");
    const addIngBtn   = document.getElementById("add-ing-btn");
    const stepsList   = document.getElementById("steps-list");
    const addStepBtn  = document.getElementById("add-step-btn");
    const formError   = document.getElementById("form-error");

    if (isEdit && formTitle) setTextSafe(formTitle, "Edit Recipe");

    // --- Tag pill preview ---
    function updateTagPills() {
      if (!fTagsPreview) return;
      fTagsPreview.innerHTML = "";
      const raw = (fTags.value || "").split(",");
      raw.forEach((tag) => {
        const t = tag.trim();
        if (t) fTagsPreview.appendChild(makePill(t));
      });
    }
    if (fTags) fTags.addEventListener("input", updateTagPills);

    // --- Dynamic ingredient sections ---
    const sectionsContainer = document.getElementById("sections-container");
    const addSectionBtn = document.getElementById("add-section-btn");

    let ingDragSrc = null;

    function makeIngredientRow(data = {}, parentList) {
      const row = document.createElement("div");
      row.className = "ingredient-row";
      row.draggable = true;

      const handle = document.createElement("span");
      handle.className = "drag-handle";
      handle.title = "Drag to reorder";
      handle.textContent = "⠿";
      row.appendChild(handle);

      const amount = document.createElement("input");
      amount.type = "text";
      amount.className = "inp-amount";
      amount.placeholder = "Amount";
      amount.value = data.amount || "";
      amount.setAttribute("aria-label", "Amount");
      row.appendChild(amount);

      const unit = document.createElement("input");
      unit.type = "text";
      unit.className = "inp-unit";
      unit.placeholder = "Unit";
      unit.value = data.unit || "";
      unit.setAttribute("aria-label", "Unit");
      row.appendChild(unit);

      const name = document.createElement("input");
      name.type = "text";
      name.placeholder = "Ingredient";
      name.value = data.name || "";
      name.className = "inp-name";
      name.setAttribute("aria-label", "Ingredient name");
      row.appendChild(name);

      const note = document.createElement("input");
      note.type = "text";
      note.className = "inp-note";
      note.placeholder = "Note";
      note.value = data.note || "";
      note.setAttribute("aria-label", "Note");
      row.appendChild(note);

      const removeBtn = document.createElement("button");
      removeBtn.type = "button";
      removeBtn.className = "remove-btn";
      removeBtn.title = "Remove";
      removeBtn.textContent = "✕";
      removeBtn.addEventListener("click", function () {
        row.remove();
      });
      row.appendChild(removeBtn);

      // Drag-and-drop within section
      row.addEventListener("dragstart", function (e) {
        ingDragSrc = row;
        e.dataTransfer.effectAllowed = "move";
        setTimeout(() => row.classList.add("dragging"), 0);
      });
      row.addEventListener("dragend", function () {
        row.classList.remove("dragging");
        ingDragSrc = null;
        document.querySelectorAll(".ingredient-row").forEach((r) =>
          r.classList.remove("drag-over")
        );
      });
      row.addEventListener("dragover", function (e) {
        e.preventDefault();
        e.dataTransfer.dropEffect = "move";
        if (ingDragSrc && ingDragSrc !== row && ingDragSrc.parentNode === parentList) {
          row.classList.add("drag-over");
        }
      });
      row.addEventListener("dragleave", function () {
        row.classList.remove("drag-over");
      });
      row.addEventListener("drop", function (e) {
        e.preventDefault();
        row.classList.remove("drag-over");
        if (ingDragSrc && ingDragSrc !== row && ingDragSrc.parentNode === parentList) {
          const allRows = [...parentList.querySelectorAll(".ingredient-row")];
          const srcIdx = allRows.indexOf(ingDragSrc);
          const tgtIdx = allRows.indexOf(row);
          if (srcIdx < tgtIdx) {
            row.after(ingDragSrc);
          } else {
            row.before(ingDragSrc);
          }
        }
      });

      return row;
    }

    function addIngredientToSection(listEl, data = {}) {
      listEl.appendChild(makeIngredientRow(data, listEl));
    }

    function makeSection(data = {}) {
      const section = document.createElement("div");
      section.className = "ingredient-section";

      // Section Header (Input + Remove btn)
      const header = document.createElement("div");
      header.className = "ingredient-section-header";
      
      const titleInp = document.createElement("input");
      titleInp.type = "text";
      titleInp.className = "section-title";
      titleInp.placeholder = "Section Name (e.g. For the Dressing)";
      titleInp.value = data.section_name || "";
      header.appendChild(titleInp);

      const removeSecBtn = document.createElement("button");
      removeSecBtn.type = "button";
      removeSecBtn.className = "section-remove-btn";
      removeSecBtn.title = "Remove Section";
      removeSecBtn.textContent = "✕";
      removeSecBtn.addEventListener("click", function() {
        section.remove();
      });
      header.appendChild(removeSecBtn);

      section.appendChild(header);

      // Ingredients List
      const listContainer = document.createElement("div");
      listContainer.className = "dynamic-list";
      section.appendChild(listContainer);

      // Populate existing rows if any
      (data.ingredients || []).forEach(ing => {
        addIngredientToSection(listContainer, ing);
      });

      // Add Ingredient Button
      const addRowBtn = document.createElement("button");
      addRowBtn.type = "button";
      addRowBtn.className = "btn btn-ghost btn-sm";
      addRowBtn.textContent = "+ Add Ingredient";
      addRowBtn.addEventListener("click", () => {
        addIngredientToSection(listContainer);
      });
      section.appendChild(addRowBtn);

      return section;
    }

    function addSection(data = {}) {
      if (!sectionsContainer) return;
      sectionsContainer.appendChild(makeSection({
        section_name: data.section_name || "",
        ingredients: data.ingredients && data.ingredients.length ? data.ingredients : [{}]
      }));
    }

    if (addSectionBtn) addSectionBtn.addEventListener("click", () => addSection());

    // --- Dynamic step rows ---
    let stepDragSrc = null;

    function makeStepRow(text = "", idx = 0) {
      const row = document.createElement("div");
      row.className = "step-row";
      row.draggable = true;

      const handle = document.createElement("span");
      handle.className = "drag-handle";
      handle.title = "Drag to reorder";
      handle.textContent = "⠿";
      row.appendChild(handle);

      const numLabel = document.createElement("span");
      numLabel.className = "step-number-label";
      row.appendChild(numLabel);

      const textarea = document.createElement("textarea");
      textarea.placeholder = "Describe this step…";
      textarea.value = text;
      textarea.setAttribute("aria-label", `Step ${idx + 1}`);
      // Auto-resize
      textarea.addEventListener("input", function () {
        this.style.height = "auto";
        this.style.height = this.scrollHeight + "px";
      });
      row.appendChild(textarea);

      const removeBtn = document.createElement("button");
      removeBtn.type = "button";
      removeBtn.className = "remove-btn";
      removeBtn.title = "Remove step";
      removeBtn.textContent = "✕";
      removeBtn.addEventListener("click", function () {
        row.remove();
        reNumberSteps();
      });
      row.appendChild(removeBtn);

      // Drag-and-drop
      row.addEventListener("dragstart", function (e) {
        stepDragSrc = row;
        e.dataTransfer.effectAllowed = "move";
        setTimeout(() => row.classList.add("dragging"), 0);
      });
      row.addEventListener("dragend", function () {
        row.classList.remove("dragging");
        stepDragSrc = null;
        document.querySelectorAll(".step-row").forEach((r) =>
          r.classList.remove("drag-over")
        );
        reNumberSteps();
      });
      row.addEventListener("dragover", function (e) {
        e.preventDefault();
        if (stepDragSrc && stepDragSrc !== row) row.classList.add("drag-over");
      });
      row.addEventListener("dragleave", function () {
        row.classList.remove("drag-over");
      });
      row.addEventListener("drop", function (e) {
        e.preventDefault();
        row.classList.remove("drag-over");
        if (stepDragSrc && stepDragSrc !== row) {
          const allRows = [...stepsList.querySelectorAll(".step-row")];
          const srcIdx = allRows.indexOf(stepDragSrc);
          const tgtIdx = allRows.indexOf(row);
          if (srcIdx < tgtIdx) row.after(stepDragSrc);
          else row.before(stepDragSrc);
          reNumberSteps();
        }
      });

      return row;
    }

    function reNumberSteps() {
      const rows = stepsList.querySelectorAll(".step-row");
      rows.forEach((row, i) => {
        const lbl = row.querySelector(".step-number-label");
        if (lbl) lbl.textContent = i + 1;
        const ta = row.querySelector("textarea");
        if (ta) ta.setAttribute("aria-label", `Step ${i + 1}`);
      });
    }

    function addStep(text = "") {
      const idx = stepsList.querySelectorAll(".step-row").length;
      const row = makeStepRow(text, idx);
      stepsList.appendChild(row);
      reNumberSteps();
    }
    if (addStepBtn) addStepBtn.addEventListener("click", () => addStep());

    // --- Populate form from data object ---
    function populateForm(data) {
      if (!data) return;
      if (fTitle) fTitle.value = data.title || "";
      if (fDesc) fDesc.value = data.description || "";
      if (fSourceUrl) fSourceUrl.value = data.source_url || "";
      if (fImageUrl) fImageUrl.value = data.image_url || "";
      if (fServings) fServings.value = data.servings || "";
      if (fPrep) fPrep.value = data.prep_time_mins || "";
      if (fCook) fCook.value = data.cook_time_mins || "";
      if (fTags) {
        fTags.value = (data.tags || []).join(", ");
        updateTagPills();
      }
      if (fNotes) fNotes.value = data.notes || "";

      // Ingredients array is ingredient_sections from backend API!
      if (sectionsContainer) sectionsContainer.innerHTML = "";
      const sections = data.ingredient_sections || data.ingredients || [];
      if (sections.length > 0) {
        sections.forEach((sec) => addSection(sec));
      } else {
        addSection();
      }

      // Steps
      if (stepsList) stepsList.innerHTML = "";
      (data.steps || []).forEach((s) => addStep(s));
    }

    // --- Load initial data ---
    async function initialize() {
      // Check sessionStorage first (scrape flow)
      const scraped = sessionStorage.getItem("scraped_recipe");
      if (scraped) {
        sessionStorage.removeItem("scraped_recipe");
        try {
          populateForm(JSON.parse(scraped));
        } catch (_) {
          // Silently ignore corrupt sessionStorage data
        }
        return;
      }

      // Edit mode: load from API
      if (isEdit) {
        try {
          const res = await fetch(`${API}/recipes/${recipeId}`);
          if (res.status === 404) {
            window.location.href = "index.html";
            return;
          }
          const recipe = await res.json();
          populateForm(recipe);
        } catch (_) {
          App.showToast("Failed to load recipe.", "error");
        }
      } else {
        // New recipe: add one empty section and step row
        addSection();
        addStep();
      }
    }

    // --- Validation ---
    function validate() {
      let valid = true;

      // Title
      const titleErr = document.getElementById("title-error");
      if (!fTitle || !fTitle.value.trim()) {
        if (fTitle) fTitle.classList.add("is-invalid");
        if (titleErr) titleErr.classList.add("visible");
        valid = false;
      } else {
        if (fTitle) fTitle.classList.remove("is-invalid");
        if (titleErr) titleErr.classList.remove("visible");
      }

      // Ingredients check
      const ingErr = document.getElementById("ing-error");
      const sections = sectionsContainer ? sectionsContainer.querySelectorAll(".ingredient-section") : [];
      
      let hasIngredient = false;
      sections.forEach(sec => {
        const rows = sec.querySelectorAll(".ingredient-row");
        rows.forEach(r => {
          const nameInput = r.querySelector(".inp-name");
          if (nameInput && nameInput.value.trim()) hasIngredient = true;
        });
      });
      
      if (!hasIngredient) {
        if (ingErr) ingErr.classList.add("visible");
        valid = false;
      } else {
        if (ingErr) ingErr.classList.remove("visible");
      }

      // Steps
      const stepsErr = document.getElementById("steps-error");
      const stepRows = stepsList ? stepsList.querySelectorAll(".step-row") : [];
      const hasStep = [...stepRows].some((row) => {
        const ta = row.querySelector("textarea");
        return ta && ta.value.trim();
      });
      if (!hasStep) {
        if (stepsErr) stepsErr.classList.add("visible");
        valid = false;
      } else {
        if (stepsErr) stepsErr.classList.remove("visible");
      }

      return valid;
    }

    // --- Build payload from form ---
    function buildPayload() {
      const sectionNodes = sectionsContainer ? sectionsContainer.querySelectorAll(".ingredient-section") : [];
      const ingredient_sections = [...sectionNodes].map((sec) => {
        const sectionName = sec.querySelector(".section-title").value.trim() || null;
        const rows = sec.querySelectorAll(".ingredient-row");
        const items = [...rows].map((r) => {
          return {
            amount: r.querySelector(".inp-amount") ? r.querySelector(".inp-amount").value.trim() : "",
            unit: r.querySelector(".inp-unit") ? r.querySelector(".inp-unit").value.trim() || null : null,
            name: r.querySelector(".inp-name") ? r.querySelector(".inp-name").value.trim() : "",
            note: r.querySelector(".inp-note") ? r.querySelector(".inp-note").value.trim() || null : null,
          };
        }).filter((i) => i.name);
        
        return {
          section_name: sectionName,
          ingredients: items
        };
      }).filter(s => s.ingredients.length > 0);

      const stepRows = stepsList ? stepsList.querySelectorAll(".step-row") : [];
      const steps = [...stepRows]
        .map((row) => {
          const ta = row.querySelector("textarea");
          return ta ? ta.value.trim() : "";
        })
        .filter(Boolean);

      const tags = (fTags ? fTags.value : "")
        .split(",")
        .map((t) => t.trim().toLowerCase())
        .filter(Boolean);

      return {
        title: fTitle ? fTitle.value.trim() : "",
        description: fDesc ? fDesc.value.trim() || null : null,
        source_url: fSourceUrl ? fSourceUrl.value.trim() || null : null,
        image_url: fImageUrl ? fImageUrl.value.trim() || null : null,
        servings: fServings ? parseInt(fServings.value) || null : null,
        prep_time_mins: fPrep ? parseInt(fPrep.value) || null : null,
        cook_time_mins: fCook ? parseInt(fCook.value) || null : null,
        tags,
        notes: fNotes ? fNotes.value.trim() || null : null,
        ingredient_sections,
        steps,
      };
    }

    // --- Save ---
    if (saveBtn) {
      saveBtn.addEventListener("click", async function () {
        if (!validate()) return;

        const payload = buildPayload();
        saveBtn.disabled = true;
        saveBtn.textContent = "Saving…";
        if (formError) formError.classList.remove("visible");

        try {
          const method = isEdit ? "PUT" : "POST";
          const url = isEdit
            ? `${API}/recipes/${recipeId}`
            : `${API}/recipes`;

          const res = await fetch(url, {
            method,
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(payload),
          });

          if (!res.ok) {
            const err = await res.json().catch(() => ({}));
            throw new Error(err.detail?.message || "Save failed");
          }

          const saved = await res.json();
          App.showToast(
            isEdit ? "Recipe updated!" : "Recipe saved!",
            "success"
          );
          window.location.href = `recipe.html?id=${saved.id}`;
        } catch (err) {
          if (formError) {
            formError.textContent = err.message || "Failed to save. Please try again.";
            formError.classList.add("visible");
          }
          saveBtn.disabled = false;
          saveBtn.textContent = isEdit ? "Save Changes" : "Save Recipe";
        }
      });
    }

    // Cancel
    if (cancelBtn) {
      cancelBtn.addEventListener("click", function () {
        if (isEdit) {
          window.location.href = `recipe.html?id=${recipeId}`;
        } else {
          window.location.href = "index.html";
        }
      });
    }

    initialize();
  };

  // ------------------------------------------------------------------
  // Router: detect page and call appropriate init
  // ------------------------------------------------------------------
  document.addEventListener("DOMContentLoaded", function () {
    const page = document.body.dataset.page;
    if (page === "index" && App.initIndex)   App.initIndex();
    if (page === "recipe" && App.initRecipe) App.initRecipe();
    if (page === "edit" && App.initEdit)     App.initEdit();
  });
})();
