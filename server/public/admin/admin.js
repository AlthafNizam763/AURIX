/*
 * AURIX appearance console.
 *
 * Talks to the same origin it is served from, so there is no CORS grant and no
 * base URL to configure. State is one `theme` object held here; every control
 * mutates it, the preview re-renders from it, and "Save changes" sends the
 * whole thing as one PUT — so a half-applied theme is not a state the server
 * can end up in.
 *
 * The access token lives in `sessionStorage`, not `localStorage`: it is scoped
 * to the tab and gone when the tab closes, which is the right lifetime for a
 * console that repaints an application for every user.
 */
(() => {
  'use strict';

  const API = '/api/v1';
  const TOKEN_KEY = 'aurix.admin.token';

  const $ = (id) => document.getElementById(id);

  /** What each colour role actually paints, shown under its swatch. */
  const ROLE_NOTES = {
    primary: 'Headings, active tabs, the brand mark',
    secondary: 'Chips, dividers, secondary surfaces',
    accent: 'Play button, focus rings, the one thing to press',
    background: 'The page itself',
    surface: 'Cards, sheets, list rows',
    text: 'Body and title text',
    player: 'Mini player and full player background',
    button: 'Filled button fill',
  };

  const PLAYER_NOTES = {
    mini: 'The bar above the tabs while something is playing.',
    large: 'The full-screen player.',
    outside: 'The notification and lock-screen surface.',
    dynamic: 'The floating Dynamic Island pill.',
  };

  const VARIANT_GLYPHS = {
    theme1: '<rect x="1" y="8" width="98" height="16" rx="4" fill="none" stroke="currentColor"/><rect x="5" y="11" width="10" height="10" rx="2" fill="currentColor"/>',
    theme2: '<rect x="1" y="8" width="98" height="16" rx="8" fill="none" stroke="currentColor"/><circle cx="10" cy="16" r="5" fill="currentColor"/>',
    theme3: '<rect x="26" y="2" width="48" height="26" rx="6" fill="none" stroke="currentColor"/><rect x="31" y="6" width="38" height="10" rx="2" fill="currentColor"/>',
  };

  let token = sessionStorage.getItem(TOKEN_KEY) || '';
  let theme = null;
  let options = null;
  let mode = 'dark';
  let dirty = false;

  // -------------------------------------------------------------------------
  // Transport
  // -------------------------------------------------------------------------

  async function api(path, { method = 'GET', body, form } = {}) {
    const headers = {};
    if (token) headers.Authorization = `Bearer ${token}`;
    if (body !== undefined) headers['Content-Type'] = 'application/json';

    const response = await fetch(API + path, {
      method,
      headers,
      body: form ?? (body !== undefined ? JSON.stringify(body) : undefined),
    });

    if (response.status === 204) return null;

    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      // An expired token is the common failure after leaving the tab open.
      // Drop straight back to the sign-in form rather than reporting an
      // authorisation error the admin can do nothing about in place.
      if (response.status === 401) signOut();
      throw new Error(payload?.error?.message || `Request failed (${response.status})`);
    }
    return payload;
  }

  function say(message, tone) {
    const banner = $('banner');
    banner.textContent = message;
    if (tone) banner.dataset.tone = tone;
    else delete banner.dataset.tone;
    banner.hidden = false;
    clearTimeout(say.timer);
    say.timer = setTimeout(() => {
      banner.hidden = true;
    }, tone === 'error' ? 8000 : 3500);
  }

  // -------------------------------------------------------------------------
  // Session
  // -------------------------------------------------------------------------

  function signOut() {
    token = '';
    sessionStorage.removeItem(TOKEN_KEY);
    $('console').hidden = true;
    $('gate').hidden = false;
  }

  $('login-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    const error = $('login-error');
    error.hidden = true;

    try {
      const result = await api('/auth/login', {
        method: 'POST',
        body: {
          email: $('login-email').value.trim(),
          password: $('login-password').value,
          device: 'admin-console',
        },
      });

      if (!result.user.isAdmin) {
        throw new Error('That account is not an administrator.');
      }

      token = result.accessToken;
      sessionStorage.setItem(TOKEN_KEY, token);
      $('who').textContent = result.user.email;
      $('login-password').value = '';
      await start();
    } catch (failure) {
      error.textContent = failure.message;
      error.hidden = false;
    }
  });

  $('logout-btn').addEventListener('click', () => {
    api('/auth/logout', { method: 'POST', body: {} }).catch(() => {});
    signOut();
  });

  // -------------------------------------------------------------------------
  // Rendering
  // -------------------------------------------------------------------------

  function renderFonts() {
    const select = $('font-family');
    select.replaceChildren();

    const families = options?.fonts ?? [{ family: theme.fontFamily, available: true }];
    const known = new Set(families.map((font) => font.family));
    // A family set by an earlier admin that is no longer in the catalogue must
    // still show as the current selection, or saving anything else would
    // silently change the font.
    if (!known.has(theme.fontFamily)) {
      families.push({ family: theme.fontFamily, available: true, custom: true });
    }

    for (const font of families) {
      const option = document.createElement('option');
      option.value = font.family;
      option.textContent = font.available
        ? font.family
        : `${font.family} — needs a font file`;
      option.selected = font.family === theme.fontFamily;
      select.append(option);
    }

    const current = families.find((font) => font.family === theme.fontFamily);
    $('font-hint').textContent = !current
      ? ''
      : current.bundled
        ? 'Ships inside the app. Always available, offline included.'
        : current.available
          ? 'Loaded from this server and cached on the device.'
          : 'No font file uploaded yet — the app keeps its current face until one is.';
  }

  function renderColors() {
    const host = $('colors');
    host.replaceChildren();

    for (const role of options?.colorRoles ?? Object.keys(ROLE_NOTES)) {
      const value = theme.colors[mode][role] ?? '#000000';

      const wrap = document.createElement('div');
      wrap.className = 'swatch';

      const picker = document.createElement('input');
      picker.type = 'color';
      // `<input type=color>` only understands #RRGGBB, so an #AARRGGBB value
      // is shown without its alpha. The hex field beside it keeps the full
      // value, which is why both controls exist.
      picker.value = toRgbHex(value);
      picker.setAttribute('aria-label', `${role} colour`);

      const body = document.createElement('div');
      body.className = 'swatch__body';

      const name = document.createElement('div');
      name.className = 'swatch__name';
      name.textContent = role;

      const hex = document.createElement('input');
      hex.type = 'text';
      hex.className = 'swatch__hex';
      hex.value = value;
      hex.spellcheck = false;

      const note = document.createElement('div');
      note.className = 'swatch__role';
      note.textContent = ROLE_NOTES[role] ?? '';

      picker.addEventListener('input', () => {
        hex.value = picker.value.toUpperCase();
        setColor(role, hex.value);
      });
      hex.addEventListener('change', () => {
        const next = normaliseHex(hex.value);
        if (!next) {
          hex.value = theme.colors[mode][role];
          say('Colours must be #RRGGBB or #AARRGGBB.', 'error');
          return;
        }
        hex.value = next;
        picker.value = toRgbHex(next);
        setColor(role, next);
      });

      body.append(name, hex, note);
      wrap.append(picker, body);
      host.append(wrap);
    }
  }

  function renderPlayers() {
    const host = $('players');
    host.replaceChildren();

    for (const { surface, variants } of options?.players ?? []) {
      const group = document.createElement('div');
      group.className = 'player-group';

      const title = document.createElement('div');
      title.className = 'player-group__name';
      title.textContent = `${surface} player`;

      const note = document.createElement('p');
      note.className = 'player-group__note';
      note.textContent = PLAYER_NOTES[surface] ?? '';

      const row = document.createElement('div');
      row.className = 'variants';

      for (const variant of variants) {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'variant';
        if (theme.musicPlayer[surface] === variant) button.classList.add('is-active');
        button.innerHTML =
          `<svg class="variant__glyph" viewBox="0 0 100 30" aria-hidden="true">${VARIANT_GLYPHS[variant] ?? ''}</svg>` +
          `<span>Theme ${variant.replace('theme', '')}</span>`;

        button.addEventListener('click', () => {
          theme.musicPlayer[surface] = variant;
          dirty = true;
          renderPlayers();
          renderPreview();
        });

        row.append(button);
      }

      group.append(title, note, row);
      host.append(group);
    }
  }

  function renderTypography() {
    const { typography } = theme;
    $('type-scale').value = typography.scale;
    $('type-scale-out').textContent = `${typography.scale.toFixed(2)}×`;
    $('type-tracking').value = typography.letterSpacing;
    $('type-tracking-out').textContent = `${typography.letterSpacing.toFixed(2)}px`;
    $('weight-regular').value = typography.weightRegular;
    $('weight-medium').value = typography.weightMedium;
    $('weight-bold').value = typography.weightBold;
    $('weight-display').value = typography.weightDisplay;
  }

  function renderAssets() {
    const logo = $('logo-preview');
    if (theme.appLogo) {
      logo.style.backgroundImage = `url("${theme.appLogo}")`;
      logo.replaceChildren();
    } else {
      logo.style.backgroundImage = '';
      logo.innerHTML = '<span class="muted">Drawn mark</span>';
    }

    const icon = $('icon-preview');
    if (theme.appIcon) {
      icon.style.backgroundImage = `url("${theme.appIcon}")`;
      icon.replaceChildren();
    } else {
      icon.style.backgroundImage = '';
      icon.innerHTML = '<span class="muted">Default icon</span>';
    }
  }

  /**
   * The preview.
   *
   * Applies the configured colours as CSS custom properties on the phone
   * element only — never on `:root`. Restyling the console from its own input
   * is how an admin loses the ability to undo an unreadable palette.
   */
  function renderPreview() {
    const palette = theme.colors[mode];
    const phone = $('phone');

    phone.style.setProperty('--pv-bg', palette.background);
    phone.style.setProperty('--pv-surface', palette.surface);
    phone.style.setProperty('--pv-text', palette.text);
    phone.style.setProperty('--pv-accent', palette.accent);
    phone.style.setProperty('--pv-primary', palette.primary);
    phone.style.setProperty('--pv-secondary', palette.secondary);
    phone.style.setProperty('--pv-player', palette.player);
    phone.style.setProperty('--pv-button', palette.button);
    phone.style.setProperty('--pv-scale', theme.typography.scale);
    phone.style.setProperty('--pv-tracking', theme.typography.letterSpacing);
    phone.style.setProperty(
      '--pv-font',
      `"${theme.fontFamily}", ui-sans-serif, system-ui, sans-serif`,
    );

    const logo = $('preview-logo');
    logo.style.backgroundImage = theme.appLogo ? `url("${theme.appLogo}")` : '';

    const player = $('preview-player');
    player.dataset.variant = theme.musicPlayer.mini;
    $('preview-caption').textContent =
      `Mini player — theme ${theme.musicPlayer.mini.replace('theme', '')}`;
  }

  function renderAll() {
    $('version-chip').textContent = `v${theme.version}`;
    renderFonts();
    renderTypography();
    renderAssets();
    renderColors();
    renderPlayers();
    renderPreview();
    $('save-btn').disabled = !dirty;
  }

  // -------------------------------------------------------------------------
  // Mutation
  // -------------------------------------------------------------------------

  function setColor(role, value) {
    theme.colors[mode][role] = value;
    dirty = true;
    $('save-btn').disabled = false;
    renderPreview();
  }

  function normaliseHex(raw) {
    const value = String(raw ?? '').trim().toUpperCase();
    if (/^#(?:[0-9A-F]{6}|[0-9A-F]{8})$/.test(value)) return value;
    if (/^(?:[0-9A-F]{6}|[0-9A-F]{8})$/.test(value)) return `#${value}`;
    // #RGB is what people type, and expanding it is friendlier than refusing.
    if (/^#?[0-9A-F]{3}$/.test(value)) {
      const body = value.replace('#', '');
      return `#${body.split('').map((c) => c + c).join('')}`;
    }
    return null;
  }

  /** `<input type=color>` speaks #RRGGBB only — drop an alpha prefix for it. */
  function toRgbHex(value) {
    const body = String(value ?? '').replace('#', '');
    if (body.length === 8) return `#${body.slice(2)}`;
    if (body.length === 6) return `#${body}`;
    return '#000000';
  }

  $('mode-switch').addEventListener('click', (event) => {
    const button = event.target.closest('button[data-mode]');
    if (!button) return;
    mode = button.dataset.mode;
    for (const sibling of $('mode-switch').children) {
      sibling.classList.toggle('is-active', sibling === button);
    }
    renderColors();
    renderPreview();
  });

  $('font-family').addEventListener('change', (event) => {
    theme.fontFamily = event.target.value;
    // The asset id belongs to the family it was uploaded for. Carrying the old
    // one over would tell the app to load Poppins' file and call it Inter.
    const picked = options?.fonts?.find((font) => font.family === theme.fontFamily);
    theme.fontAssetId = picked?.assetId ?? null;
    dirty = true;
    renderFonts();
    renderPreview();
    $('save-btn').disabled = false;
  });

  for (const [id, key, parse] of [
    ['type-scale', 'scale', Number.parseFloat],
    ['type-tracking', 'letterSpacing', Number.parseFloat],
    ['weight-regular', 'weightRegular', Number.parseInt],
    ['weight-medium', 'weightMedium', Number.parseInt],
    ['weight-bold', 'weightBold', Number.parseInt],
    ['weight-display', 'weightDisplay', Number.parseInt],
  ]) {
    $(id).addEventListener('input', (event) => {
      const value = parse(event.target.value, 10);
      if (!Number.isFinite(value)) return;
      theme.typography[key] = value;
      dirty = true;
      renderTypography();
      renderPreview();
      $('save-btn').disabled = false;
    });
  }

  // -------------------------------------------------------------------------
  // Uploads
  // -------------------------------------------------------------------------

  async function upload(path, input, extra = {}) {
    const file = input.files?.[0];
    if (!file) {
      say('Choose a file first.', 'error');
      return null;
    }

    const form = new FormData();
    form.append('file', file);
    for (const [key, value] of Object.entries(extra)) form.append(key, value);

    const result = await api(path, { method: 'POST', form });
    input.value = '';
    return result;
  }

  $('logo-upload-btn').addEventListener('click', async () => {
    try {
      const result = await upload('/theme/logo', $('logo-file'));
      if (!result) return;
      theme = result.theme;
      dirty = false;
      renderAll();
      say('Logo updated and live.');
    } catch (error) {
      say(error.message, 'error');
    }
  });

  $('logo-clear-btn').addEventListener('click', async () => {
    try {
      theme = (await api('/theme/logo', { method: 'DELETE' })).theme;
      dirty = false;
      renderAll();
      say('Logo reset to the drawn mark.');
    } catch (error) {
      say(error.message, 'error');
    }
  });

  $('icon-upload-btn').addEventListener('click', async () => {
    try {
      const result = await upload('/theme/icon', $('icon-file'));
      if (!result) return;
      theme = result.theme;
      dirty = false;
      renderAll();
      say('App icon updated.');
    } catch (error) {
      say(error.message, 'error');
    }
  });

  $('icon-clear-btn').addEventListener('click', async () => {
    try {
      theme = (await api('/theme/icon', { method: 'DELETE' })).theme;
      dirty = false;
      renderAll();
      say('App icon reset.');
    } catch (error) {
      say(error.message, 'error');
    }
  });

  $('font-upload-btn').addEventListener('click', async () => {
    const family = $('font-name').value.trim();
    if (!family) {
      say('Name the font family first — the app looks it up by that name.', 'error');
      return;
    }
    try {
      const result = await upload('/theme/fonts', $('font-file'), { family, apply: 'true' });
      if (!result) return;
      theme = result.theme;
      options = await api('/theme/options');
      dirty = false;
      renderAll();
      say(`${family} uploaded and applied.`);
    } catch (error) {
      say(error.message, 'error');
    }
  });

  // -------------------------------------------------------------------------
  // Save / reset
  // -------------------------------------------------------------------------

  $('save-btn').addEventListener('click', async () => {
    const button = $('save-btn');
    button.disabled = true;
    try {
      const result = await api('/theme', {
        method: 'PUT',
        body: {
          fontFamily: theme.fontFamily,
          fontAssetId: theme.fontAssetId,
          typography: theme.typography,
          colors: theme.colors,
          musicPlayer: theme.musicPlayer,
        },
      });
      theme = result.theme;
      dirty = false;
      renderAll();
      say(`Saved. Every app will pick up version ${theme.version} on its next launch or refresh.`);
    } catch (error) {
      button.disabled = false;
      say(error.message, 'error');
    }
  });

  $('reset-btn').addEventListener('click', async () => {
    if (!confirm('Restore the shipped AURIX appearance? Uploaded logos stay available.')) return;
    try {
      theme = (await api('/theme/reset', { method: 'POST' })).theme;
      dirty = false;
      renderAll();
      say('Appearance reset to the shipped default.');
    } catch (error) {
      say(error.message, 'error');
    }
  });

  window.addEventListener('beforeunload', (event) => {
    if (!dirty) return;
    event.preventDefault();
    event.returnValue = '';
  });

  // -------------------------------------------------------------------------
  // Boot
  // -------------------------------------------------------------------------

  async function start() {
    [theme, options] = await Promise.all([
      api('/theme').then((result) => result.theme),
      api('/theme/options'),
    ]);
    dirty = false;
    renderAll();
    $('gate').hidden = true;
    $('console').hidden = false;
  }

  (async () => {
    if (!token) return signOut();
    try {
      const me = await api('/auth/me');
      if (!me.user.isAdmin) return signOut();
      $('who').textContent = me.user.email;
      await start();
    } catch {
      signOut();
    }
  })();
})();
