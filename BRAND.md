# GameHub Brand Identity

This is the single source of truth for GameHub's visual identity across
the web app (`frontend/`) and the native Android app (`mobile/`). When
adding a new screen, page, or game to either platform, match this
document rather than improvising new colors/spacing - and if you have
to deviate, update this file so it stays authoritative.

## Logo / App Icon

A white "GH" monogram (Segoe UI Bold, or the closest available bold
sans-serif) centered on a solid brand-purple background. No gradients,
no additional ornamentation.

- Source files: `frontend/static/icons/icon-192.png`, `icon-512.png`,
  `icon-512-maskable.png` (maskable version uses a smaller monogram -
  ~42% of canvas width instead of ~50% - to survive Android's adaptive
  icon safe-zone cropping).
- Regenerate with `scripts/` is not checked in - see git history for the
  PIL-based generator script if the icon ever needs to change; keep the
  brand purple background and white monogram convention.
- The Android launcher icon (`mobile/assets/icon/icon.png`, propagated
  via `flutter_launcher_icons`) must always be a copy of
  `frontend/static/icons/icon-512.png` - one source of truth, not two
  separately-maintained icons.
- Minimum clear space: leave at least 10% of the icon's width as empty
  margin around the monogram at every size.
- Never place the monogram on white or light backgrounds - it's
  designed for the brand-purple fill only. For a wordmark on a light
  page background (e.g. web headers), use the text "GameHub" in the
  text color instead (see Wordmark below).

## Wordmark

Where the app name appears as text (login screens, page headers), it's
set in the platform's default bold weight, not a custom logotype:
"GameHub" - always one word, capital G and H, no space. See
`.brand-mark` / `.auth-logo` in `frontend/static/css/style.css` for the
web treatment (700 weight, sized to context) and `login_screen.dart`
for the mobile equivalent.

## Color Palette

The single brand color is **indigo `#4F46E5`**. Everything else is a
neutral gray scale plus two semantic colors (error/success). Both
platforms define a light and a dark variant; which one is active
follows the OS-level light/dark setting (`prefers-color-scheme` on web,
`ColorScheme` brightness on Android) - there is no in-app theme toggle.

### Light mode

| Role | Hex | Usage |
|---|---|---|
| Background | `#F1F5F9` | Page/app background |
| Panel/surface | `#FFFFFF` | Cards, form panels |
| Text | `#0F172A` | Primary text |
| Text muted | `#64748B` | Labels, secondary text |
| Border | `#E2E8F0` | Panel borders, dividers |
| Brand | `#4F46E5` | Primary actions, links, focus rings |
| Brand hover | `#4338CA` | Hover/pressed state of brand elements |
| Input background | `#FFFFFF` | Text field fill |
| Input border | `#CBD5E1` | Text field border |
| Error | `#DC2626` | Error text/states |
| Success | `#16A34A` | Success text/states |
| Shadow | `rgba(15, 23, 42, 0.08)` | Panel drop shadows |

### Dark mode

| Role | Hex | Usage |
|---|---|---|
| Background | `#0B1220` | Page/app background |
| Panel/surface | `#1A2436` | Cards, form panels |
| Text | `#F1F5F9` | Primary text |
| Text muted | `#94A3B8` | Labels, secondary text |
| Border | `#2D3B52` | Panel borders, dividers |
| Brand | `#818CF8` | Primary actions, links, focus rings (lightened for contrast on dark bg) |
| Brand hover | `#A5B4FC` | Hover/pressed state of brand elements |
| Input background | `#10192B` | Text field fill |
| Input border | `#3A4A63` | Text field border |
| Error | `#F87171` | Error text/states |
| Success | `#4ADE80` | Success text/states |
| Shadow | `rgba(0, 0, 0, 0.45)` | Panel drop shadows |

Source of truth: the CSS custom properties in
`frontend/static/css/style.css` (`:root` and the
`prefers-color-scheme: dark` block). The Flutter app's `ColorScheme`
in `mobile/lib/main.dart` mirrors these exact hex values rather than
letting Material 3 auto-derive a dark palette from the seed color, so
the two platforms' dark modes actually match instead of just being
"in the same family."

Per-game accent colors (e.g. Connect Four's red/yellow discs, Ludo's
four player colors) are exempt from this palette - those are gameplay
colors, not brand colors, and stay as-is.

## Typography

- **Web**: system font stack -
  `-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif`
  (see `body` in `style.css`). No web fonts are loaded - this keeps
  pages fast and makes text render in whatever font already looks
  native to the visitor's OS.
- **Mobile**: Flutter/Material's default platform font (Roboto on
  Android). Deliberately not forcing the web's font stack here - a
  native app should use native-feeling type rendering, not imitate the
  web page's font choice.
- **Weights**: page/section titles and the wordmark are bold (700).
  Body text is regular. Labels and muted/secondary text are semibold
  (600) but smaller and in the muted color, not bold.

## Shape & Spacing

- **Corner radius**: 8px on buttons and inputs, 12-14px on cards/panels.
  Nothing is fully square; nothing is fully pill-shaped except where
  Material's default button shape is left as-is on mobile.
- **Buttons**: full-width by default in forms (web and mobile both).
  Primary action = solid brand-purple fill, white text. Secondary
  action = transparent fill, bordered, text-colored.
- Consistent internal padding rather than tight/cramped layouts -
  panels use ~36px padding on web forms; mobile screens use 16-24px
  screen-edge padding.

## Voice

Product copy is plain and short - "Log In", "Sync Now", "Play Offline
as Guest" - not cute or verbose. Error messages state what happened and
what to do next ("No connection. Check your internet and try again."),
not just an error code.

## Applying this to a new screen or page

1. Reuse the color roles above by name (brand / text / text-muted /
   border / error / success), never a one-off hex value.
2. Reuse the existing spacing/radius conventions rather than picking
   new numbers.
3. If a new screen genuinely needs something this document doesn't
   cover, add it here in the same pass - don't let the doc drift out
   of date with what's actually shipped.
