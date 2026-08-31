'use client';

import { useActionState } from 'react';

import { Field, Notice, Panel, buttonStyles, inputStyles } from '@components/ui';

import {
  clearBrandImage,
  restoreDefaults,
  saveColours,
  saveTypography,
  uploadBrandImage,
  type ThemeState,
} from './actions';

interface ThemeShape {
  version: number;
  fontFamily: string;
  colors: { dark: Record<string, string>; light: Record<string, string> };
  typography: { [key: string]: number };
  musicPlayer: Record<string, string>;
  appLogo: string | null;
  appIcon: string | null;
}

/**
 * The appearance forms.
 *
 * A client component because each of the five forms reports its own result, and
 * a colour input that cannot show the swatch it is about to set is not really a
 * colour input. The values it starts from are rendered on the server.
 *
 * Each `<form>` posts to its own Server Action, which re-checks administrator
 * access — the layout's guard does not run for an action.
 */
export function AppearanceEditor({
  theme,
  colorKeys,
  playerSurfaces,
  playerVariants,
  fonts,
}: {
  theme: ThemeShape;
  colorKeys: string[];
  playerSurfaces: string[];
  playerVariants: string[];
  fonts: { family: string; note: string; available: boolean; bundled: boolean }[];
}) {
  return (
    <div className="space-y-6">
      <ColourForm
        theme={theme}
        colorKeys={colorKeys}
        playerSurfaces={playerSurfaces}
        playerVariants={playerVariants}
        fonts={fonts}
      />
      <TypographyForm theme={theme} />
      <BrandImages theme={theme} />
      <ResetPanel />
    </div>
  );
}

function Result({ state }: { state: ThemeState }) {
  if (state.error) return <Notice tone="error">{state.error}</Notice>;
  if (state.message) return <Notice tone="success">{state.message}</Notice>;
  return null;
}

/** A hex field paired with a native swatch, both writing the same value. */
function ColourInput({ name, value }: { name: string; value: string }) {
  return (
    <div className="flex items-center gap-2">
      <input
        type="color"
        // The swatch is a convenience; the text field is the source of truth,
        // because `<input type="color">` cannot express the #AARRGGBB form the
        // theme accepts.
        defaultValue={value.slice(0, 7)}
        onChange={(event) => {
          const text = event.currentTarget.parentElement?.querySelector('input[type=text]');
          if (text instanceof HTMLInputElement) text.value = event.currentTarget.value.toUpperCase();
        }}
        className="h-9 w-9 shrink-0 cursor-pointer rounded border border-hairline-strong bg-transparent"
        aria-hidden
        tabIndex={-1}
      />
      <input
        type="text"
        name={name}
        defaultValue={value}
        spellCheck={false}
        className={`${inputStyles} font-mono uppercase`}
        aria-label={name}
      />
    </div>
  );
}

function ColourForm({
  theme,
  colorKeys,
  playerSurfaces,
  playerVariants,
  fonts,
}: {
  theme: ThemeShape;
  colorKeys: string[];
  playerSurfaces: string[];
  playerVariants: string[];
  fonts: { family: string; note: string; available: boolean; bundled: boolean }[];
}) {
  const [state, action, pending] = useActionState<ThemeState, FormData>(saveColours, {});

  return (
    <Panel
      title="Colours, font and player"
      description="Dark is the primary colourway. Light is designed, not derived — both are stored."
    >
      <form action={action} className="space-y-6">
        <Result state={state} />

        <div className="grid gap-x-6 gap-y-4 sm:grid-cols-2">
          <div className="space-y-3">
            <h3 className="text-xs font-medium tracking-[0.15em] text-ink-tertiary uppercase">
              Dark
            </h3>
            {colorKeys.map((key) => (
              <Field key={`dark-${key}`} label={key}>
                <ColourInput name={`dark.${key}`} value={theme.colors.dark[key] ?? '#000000'} />
              </Field>
            ))}
          </div>

          <div className="space-y-3">
            <h3 className="text-xs font-medium tracking-[0.15em] text-ink-tertiary uppercase">
              Light
            </h3>
            {colorKeys.map((key) => (
              <Field key={`light-${key}`} label={key}>
                <ColourInput name={`light.${key}`} value={theme.colors.light[key] ?? '#FFFFFF'} />
              </Field>
            ))}
          </div>
        </div>

        <div className="grid gap-4 border-t border-hairline pt-5 sm:grid-cols-2">
          <Field
            label="Font family"
            hint="Bundled faces work offline. Others need a file on the Uploads screen."
          >
            <select name="fontFamily" defaultValue={theme.fontFamily} className={inputStyles}>
              {fonts.map((font) => (
                <option key={font.family} value={font.family} disabled={!font.available}>
                  {font.family}
                  {font.bundled ? '' : font.available ? ' (uploaded)' : ' — needs a file'}
                </option>
              ))}
            </select>
          </Field>

          {playerSurfaces.map((surface) => (
            <Field key={surface} label={`Player · ${surface}`}>
              <select
                name={`player.${surface}`}
                defaultValue={theme.musicPlayer[surface]}
                className={inputStyles}
              >
                {playerVariants.map((variant) => (
                  <option key={variant} value={variant}>
                    {variant}
                  </option>
                ))}
              </select>
            </Field>
          ))}
        </div>

        <button type="submit" className={buttonStyles.primary} disabled={pending}>
          {pending ? 'Saving…' : 'Save appearance'}
        </button>
      </form>
    </Panel>
  );
}

function TypographyForm({ theme }: { theme: ThemeShape }) {
  const [state, action, pending] = useActionState<ThemeState, FormData>(saveTypography, {});

  // The ranges are the service's, restated so the browser refuses out-of-bounds
  // values before a round trip. The server clamps regardless.
  const fields = [
    { name: 'scale', label: 'Scale', min: 0.8, max: 1.4, step: 0.05 },
    { name: 'letterSpacing', label: 'Letter spacing', min: -1, max: 2, step: 0.1 },
    { name: 'weightRegular', label: 'Regular', min: 100, max: 900, step: 100 },
    { name: 'weightMedium', label: 'Medium', min: 100, max: 900, step: 100 },
    { name: 'weightBold', label: 'Bold', min: 100, max: 900, step: 100 },
    { name: 'weightDisplay', label: 'Display', min: 100, max: 900, step: 100 },
  ];

  return (
    <Panel
      title="Typography"
      description="A multiplier on the whole scale, not fifteen independent sizes — the proportions are the design."
    >
      <form action={action} className="space-y-5">
        <Result state={state} />

        <div className="grid gap-4 sm:grid-cols-3">
          {fields.map((field) => (
            <Field key={field.name} label={field.label}>
              <input
                className={inputStyles}
                type="number"
                name={field.name}
                defaultValue={theme.typography[field.name]}
                min={field.min}
                max={field.max}
                step={field.step}
              />
            </Field>
          ))}
        </div>

        <button type="submit" className={buttonStyles.primary} disabled={pending}>
          {pending ? 'Saving…' : 'Save typography'}
        </button>
      </form>
    </Panel>
  );
}

function BrandImages({ theme }: { theme: ThemeShape }) {
  return (
    <div className="grid gap-6 lg:grid-cols-2">
      <BrandImage role="logo" current={theme.appLogo} />
      <BrandImage role="icon" current={theme.appIcon} />
    </div>
  );
}

function BrandImage({ role, current }: { role: 'logo' | 'icon'; current: string | null }) {
  const [uploadState, upload, uploading] = useActionState<ThemeState, FormData>(
    uploadBrandImage,
    {},
  );
  const [clearState, clear, clearing] = useActionState<ThemeState, FormData>(
    clearBrandImage,
    {},
  );

  return (
    <Panel
      title={role === 'logo' ? 'Logo' : 'App icon'}
      description="PNG, JPEG, WebP or GIF. SVG is refused — it can carry script."
    >
      <div className="space-y-4">
        <Result state={uploadState.error || uploadState.message ? uploadState : clearState} />

        <div className="flex h-24 items-center justify-center rounded-lg border border-dashed border-hairline bg-ground-deep">
          {current ? (
            // eslint-disable-next-line @next/next/no-img-element -- served from
            // GridFS through our own route; the optimizer adds nothing here.
            <img src={current} alt={`Current ${role}`} className="max-h-16 max-w-[70%] object-contain" />
          ) : (
            <span className="text-xs text-ink-tertiary">Nothing uploaded — using the default</span>
          )}
        </div>

        <form action={upload} className="space-y-3">
          <input type="hidden" name="role" value={role} />
          <input
            type="file"
            name="file"
            accept="image/png,image/jpeg,image/webp,image/gif"
            required
            className="block w-full text-xs text-ink-secondary file:mr-3 file:rounded-lg file:border-0 file:bg-surface-elevated file:px-3 file:py-2 file:text-xs file:text-ink"
          />
          <button type="submit" className={buttonStyles.secondary} disabled={uploading}>
            {uploading ? 'Uploading…' : `Upload ${role}`}
          </button>
        </form>

        {current ? (
          <form action={clear}>
            <input type="hidden" name="role" value={role} />
            <button type="submit" className={buttonStyles.ghost} disabled={clearing}>
              {clearing ? 'Removing…' : `Remove ${role}`}
            </button>
          </form>
        ) : null}
      </div>
    </Panel>
  );
}

function ResetPanel() {
  const [state, action, pending] = useActionState<ThemeState, FormData>(restoreDefaults, {});

  return (
    <Panel
      title="Restore the AURIX identity"
      description="Puts every colour, weight and player surface back to what the app shipped with. The version keeps climbing, so installs still notice."
    >
      <form action={action} className="space-y-4">
        <Result state={state} />
        <button type="submit" className={buttonStyles.secondary} disabled={pending}>
          {pending ? 'Restoring…' : 'Restore defaults'}
        </button>
      </form>
    </Panel>
  );
}
