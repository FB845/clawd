// Little bits of life for the Clawd page. No network requests, no storage.
(() => {
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const img = (name) => `img/${name}.png`;

  // Preload every pose we swap to, so swaps never flash.
  const poses = ["idle", "blink", "walk1", "walk2", "pet", "look-up", "happy", "alert", "done", "sulky",
    "bash", "edit", "read", "web", "agent", "thinking0", "thinking1", "thinking2", "thinking3", "thinking4",
    "thinking5", "dizzy", "typing", "sleep", "lowbatt", "clipboard", "cookie0", "cookie1", "cookie2", "eating"];
  poses.forEach((p) => { const i = new Image(); i.src = img(p); });

  // ---- Hero: Clawd strolls along the window's top edge, blinks, and loves a pet.
  const scene = document.querySelector(".scene");
  const heroBtn = document.getElementById("heroPet");
  const hero = heroBtn.querySelector("img");
  let x = 30, dir = 1, mode = "walk", modeUntil = 0, step = 0, lastStep = 0, petCount = 0;
  const now = () => performance.now();

  function setHero(name, flip = false) {
    const src = img(name);
    if (!hero.src.endsWith(src)) hero.src = src;
    hero.style.transform = flip ? "scaleX(-1)" : "";
  }

  function heroTick(t) {
    const w = scene.clientWidth;
    const petW = heroBtn.offsetWidth;
    // Keep the body (40% into the image) over the window, which spans 9%..91% (5%..95% on phones).
    const winL = w < 560 ? 0.05 : 0.09;
    const minX = (winL * w - petW * 0.06) / w * 100;
    const maxX = ((1 - winL) * w - petW * 0.75) / w * 100;

    if (mode === "walk") {
      x += dir * 0.045;
      if (x > maxX) { x = maxX; dir = -1; }
      if (x < minX) { x = minX; dir = 1; }
      if (t - lastStep > 170) { step = 1 - step; lastStep = t; }
      setHero(step ? "walk1" : "walk2", dir < 0);
      if (Math.random() < 0.002) { mode = "pause"; modeUntil = t + 1600 + Math.random() * 1800; }
    } else if (mode === "pause") {
      const blinking = (t % 3200) < 140;
      setHero(blinking ? "blink" : (Math.floor(t / 2400) % 3 === 2 ? "look-up" : "idle"));
      if (t > modeUntil) mode = "walk";
    } else if (mode === "pet") {
      setHero(petCount >= 6 ? "dizzy" : "pet");
      if (t > modeUntil) { mode = "pause"; modeUntil = t + 900; if (petCount >= 6) petCount = 0; }
    }
    heroBtn.style.left = x + "%";
    requestAnimationFrame(heroTick);
  }

  heroBtn.addEventListener("click", () => {
    petCount++;
    mode = "pet";
    modeUntil = now() + 1700;
    heroBtn.classList.remove("hopping"); void heroBtn.offsetWidth; heroBtn.classList.add("hopping");
    const hint = document.querySelector(".scene-hint");
    if (hint) hint.textContent = petCount >= 6 ? "too many pets: dizzy!" : "♥";
  });

  if (reduce) {
    setHero("idle");
    // Still blink occasionally; it's tiny.
    setInterval(() => { setHero("blink"); setTimeout(() => setHero("idle"), 140); }, 4000);
    heroBtn.addEventListener("click", () => { setHero("pet"); setTimeout(() => setHero("idle"), 1600); });
  } else {
    requestAnimationFrame(heroTick);
  }

  // ---- Companion: cycle through what Claude Code is doing.
  const statusPet = document.getElementById("statusPet");
  const caption = document.getElementById("statusCaption");
  const list = document.getElementById("statusList");
  const buttons = [...list.querySelectorAll("button")];
  const labels = {
    thinking: ["Thinking…", "Clawd thinking, with a spinner in its thought bubble"],
    bash: ["Running a command", "Clawd thinking about a hammer"],
    edit: ["Editing a file", "Clawd thinking about a pencil"],
    read: ["Reading and searching", "Clawd thinking about a magnifying glass"],
    web: ["Fetching the web", "Clawd thinking about a globe"],
    agent: ["Spawned a subagent", "Clawd thinking about a tiny Clawd"],
    done: ["Done!", "Clawd happy, with a green check"],
  };
  const order = Object.keys(labels);
  let current = 0, spinTimer = null, cycleTimer = null, userPicked = false;

  function showStatus(i) {
    current = i;
    const key = order[i];
    buttons.forEach((b, k) => b.classList.toggle("on", k === i));
    caption.textContent = labels[key][0];
    statusPet.alt = labels[key][1];
    clearInterval(spinTimer);
    if (key === "thinking" && !reduce) {
      let f = 0;
      statusPet.src = img("thinking0");
      spinTimer = setInterval(() => { f = (f + 1) % 6; statusPet.src = img("thinking" + f); }, 130);
    } else {
      statusPet.src = img(key === "thinking" ? "thinking0" : key);
    }
    if (key === "done" && !reduce) {
      const box = statusPet.parentElement;
      box.classList.remove("hopping"); void box.offsetWidth; box.classList.add("hopping");
    }
  }

  function startCycle() {
    clearInterval(cycleTimer);
    if (reduce || userPicked) return;
    cycleTimer = setInterval(() => showStatus((current + 1) % order.length), 2200);
  }

  buttons.forEach((b, i) => b.addEventListener("click", () => {
    userPicked = true;
    clearInterval(cycleTimer);
    showStatus(i);
  }));
  showStatus(0);

  // Only cycle while the section is on screen.
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (e.isIntersecting) startCycle();
      else clearInterval(cycleTimer);
    });
  });
  io.observe(document.getElementById("companion"));

  // ---- Approval demo: buttons arm after half a second, like the real card.
  const card = document.getElementById("approvalCard");
  const approvalPet = document.getElementById("approvalPet");
  const cardBtns = [...card.querySelectorAll(".pxbtn")];
  function presentCard() {
    card.classList.remove("answered", "armed");
    approvalPet.src = img("alert");
    approvalPet.alt = "Clawd hopping up with a permission request";
    cardBtns.forEach((b) => (b.disabled = true));
    setTimeout(() => { cardBtns.forEach((b) => (b.disabled = false)); card.classList.add("armed"); }, 500);
  }
  cardBtns.forEach((b) => b.addEventListener("click", () => {
    const allow = b.dataset.answer === "allow";
    card.classList.add("answered");
    approvalPet.src = img(allow ? "done" : "idle");
    approvalPet.alt = allow ? "Clawd happy: allowed" : "Clawd back to normal: denied";
    setTimeout(presentCard, 2400);
  }));
  presentCard();

  // ---- Usage mock: 14 days of made-up numbers.
  const days = [31, 44, 27, 8, 5, 52, 61, 38, 47, 29, 9, 12, 57, 48.2];
  const chart = document.getElementById("chart");
  const tip = document.getElementById("chartTip");
  const max = Math.max(...days);
  const today = new Date();
  const fmt = new Intl.DateTimeFormat("en-US", { weekday: "short", month: "short", day: "numeric" });
  days.forEach((v, i) => {
    const d = new Date(today); d.setDate(today.getDate() - (days.length - 1 - i));
    const bar = document.createElement("span");
    bar.className = "bar" + (i === days.length - 1 ? " today" : "");
    bar.style.height = (v / max * 100) + "%";
    bar.tabIndex = 0;
    const label = `${i === days.length - 1 ? "Today" : fmt.format(d)}: ${v.toFixed(1)}k tokens`;
    bar.setAttribute("aria-label", label);
    const show = () => (tip.textContent = label);
    bar.addEventListener("mouseenter", show);
    bar.addEventListener("focus", show);
    bar.addEventListener("click", show);
    chart.appendChild(bar);
  });
  chart.addEventListener("mouseleave", () => (tip.textContent = "Hover a bar"));

  // ---- By-project window: made-up projects.
  const colors = ["#d97757", "#5c6ee0", "#45b06b", "#e8b84d", "#9e6bcc"];
  const data = {
    today: [["my-website", 21.6, 2], ["api-server", 14.1, 1], ["dotfiles", 7.9, 1], ["recipe-app", 4.6, 1]],
    week: [["my-website", 88, 9], ["api-server", 58, 6], ["dotfiles", 30, 3], ["recipe-app", 23, 4], ["notes", 15, 2]],
    month: [["api-server", 352, 21], ["my-website", 318, 27], ["recipe-app", 171, 12], ["dotfiles", 104, 8], ["notes", 75, 6]],
  };
  const sessions = ["Fix the login redirect", "Add dark mode", "Write tests for the parser", "Tidy up the README", "Speed up image loading", "Refactor the settings page"];
  const k = (n) => (n >= 1000 ? (n / 1000).toFixed(2).replace(/0$/, "") + "M" : (n % 1 ? n.toFixed(1) : n) + "k");
  const projectsEl = document.getElementById("projects");
  const shareEl = document.getElementById("shareBar");
  function renderPeriod(p) {
    const rows = data[p];
    const total = rows.reduce((s, r) => s + r[1], 0);
    document.getElementById("detailTotal").textContent = k(Math.round(total * 10) / 10);
    document.getElementById("detailCount").textContent = rows.length;
    shareEl.innerHTML = rows.map((r, i) => `<span style="flex-grow:${r[1]};background:${colors[i]}"></span>`).join("");
    projectsEl.innerHTML = rows.map((r, i) => {
      const [name, t, n] = r;
      const inp = t * 0.13, out = t * 0.62, cw = t * 0.25;
      const ss = sessions.slice(i % 3, (i % 3) + Math.min(n, 3)).map((s, j) =>
        `<li><span>${s}</span><span>${k(Math.round(t / (j + 2) * 10) / 10)}</span></li>`).join("");
      return `<li><details${i === 0 ? " open" : ""}><summary>
        <span class="sw" style="background:${colors[i]}"></span>
        <span class="nm">${name}</span><span class="tk">${k(t)}</span><span class="pc">${Math.round(t / total * 100)}%</span>
      </summary><div class="proj-more">
        <div class="proj-stats"><div><span>Input</span>${k(Math.round(inp * 10) / 10)}</div><div><span>Output</span>${k(Math.round(out * 10) / 10)}</div><div><span>Cache write</span>${k(Math.round(cw * 10) / 10)}</div><div><span>Sessions</span>${n}</div></div>
        <ul class="proj-sessions">${ss}</ul>
      </div></details></li>`;
    }).join("");
  }
  document.querySelectorAll(".seg button").forEach((b) => b.addEventListener("click", () => {
    document.querySelectorAll(".seg button").forEach((o) => o.setAttribute("aria-selected", String(o === b)));
    renderPeriod(b.dataset.period);
  }));
  renderPeriod("week");

  // ---- Life tiles.
  // Walker: swap leg frames and face the way it's going.
  document.querySelectorAll("[data-walk]").forEach((w) => {
    const im = w.querySelector("img");
    if (reduce) return;
    let s = 0;
    setInterval(() => { s = 1 - s; im.src = img(s ? "walk1" : "walk2"); }, 180);
    w.addEventListener("animationiteration", () => w.classList.toggle("left"));
  });
  // Notices-your-Mac tile: cycle through reactions.
  document.querySelectorAll("[data-cycle]").forEach((c) => {
    const names = c.dataset.cycle.split(",");
    const im = c.querySelector("img");
    if (reduce) return;
    let i = 0;
    setInterval(() => { i = (i + 1) % names.length; im.src = img(names[i]); }, 1800);
  });
  // Cookie: click to take a bite.
  const cookie = document.getElementById("cookie");
  let bites = 0;
  cookie.addEventListener("click", () => {
    bites = (bites + 1) % 4;
    if (bites === 3) { cookie.style.visibility = "hidden"; setTimeout(() => { bites = 0; cookie.src = img("cookie0"); cookie.style.visibility = ""; }, 900); }
    else cookie.src = img("cookie" + bites);
  });
  cookie.title = "Take a bite";
})();
