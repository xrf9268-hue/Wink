// Wink logo marks — v2.
// The closed eye is drawn as a CONCAVE-UP arc (⌣, like a cup/smile),
// NOT a convex-up bump (⌒). In SVG (y-down), that means the control
// point's Y is LARGER than the endpoints' Y — the middle of the arc
// sits BELOW the ends. Paired with a solid dot to the right, this
// reads unambiguously as "closed smiling eye + open eye" wink.
// Inverted arcs read as sad/frown in context, which was v1's bug.
//
// All marks use currentColor so they template for menu bar.
// All tuned to stay legible at 14–18px.

// ============================================================
// A. Wink Twin — the anchor, Apple product-style redesign.
//
// Construction (32u grid, mirroring Apple's system-icon idiom —
// Apple logo, Siri orb, moon/Focus glyphs are all built from pure
// circles on a grid, not hand-tuned beziers):
//   • Crescent = boolean subtraction of two perfect circles.
//       - Outer disc  r = 9  at (12, 16)
//       - Cutter disc r = 8  at (15.2, 13.4)
//     Built via even-odd fill-rule, so crescent waist (≈4.4u) equals
//     the open-eye diameter (4.4u) — shared optical weight.
//   • Open eye = true circle, r = 2.2, at (25, 16).
//   • Both shapes share optical baseline y = 16.
//   • 26u safe area inside the 32u grid (Apple keyline).
//
// Two finishes from one geometry:
//   - variant="flat"        → template-tintable single color (menu bar,
//                              wordmark, small sizes). Default.
//   - variant="dimensional" → soft top highlight + specular for the
//                              squircle app-icon tile. Light source
//                              top-left, no skeuomorphic bevel.
// ============================================================
function Logo_WinkTwin({
  size = 64,
  color = 'currentColor',
  variant = 'flat',
  idPrefix = 'wt',
}) {
  const uid = React.useMemo(
    () => `${idPrefix}-${Math.random().toString(36).slice(2, 8)}`,
    [idPrefix]
  );

  // Crescent = outer circle - cutter circle (evenodd).
  const crescentD =
    'M12 7 a9 9 0 1 0 0 18 a9 9 0 1 0 0 -18 Z ' +
    'M15.2 5.4 a8 8 0 1 1 0 16 a8 8 0 1 1 0 -16 Z';

  if (variant === 'dimensional') {
    return (
      <svg width={size} height={size} viewBox="0 0 32 32">
        <defs>
          <linearGradient id={`${uid}-grad`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#ffffff" stopOpacity="0.22" />
            <stop offset="1" stopColor="#ffffff" stopOpacity="0" />
          </linearGradient>
          <radialGradient id={`${uid}-specular`} cx="0.35" cy="0.25" r="0.6">
            <stop offset="0" stopColor="#ffffff" stopOpacity="0.55" />
            <stop offset="0.6" stopColor="#ffffff" stopOpacity="0" />
          </radialGradient>
        </defs>
        <g fill={color}>
          <path d={crescentD} fillRule="evenodd" />
          <circle cx="25" cy="16" r="2.2" />
        </g>
        <g style={{ mixBlendMode: 'screen' }}>
          <path d={crescentD} fillRule="evenodd" fill={`url(#${uid}-grad)`} />
          <circle cx="25" cy="16" r="2.2" fill={`url(#${uid}-grad)`} />
        </g>
        <path
          d={crescentD}
          fillRule="evenodd"
          fill={`url(#${uid}-specular)`}
          style={{ mixBlendMode: 'screen' }}
        />
      </svg>
    );
  }

  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill={color}>
      <path d={crescentD} fillRule="evenodd" />
      <circle cx="25" cy="16" r="2.2" />
    </svg>
  );
}

// ============================================================
// B. Wink Lash — the character version. Same twin eyes + a single
//    lash tick above the open eye, suggesting it just winked back
//    open. Slightly more personality without tipping into emoji.
// ============================================================
function Logo_WinkLash({ size = 64, color = 'currentColor' }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      {/* closed eye — concave-up */}
      <path
        d="M5 13 Q 10 18, 15 13"
        stroke={color} strokeWidth="2.6"
        strokeLinecap="round" fill="none"
      />
      {/* open eye */}
      <circle cx="22.5" cy="15.5" r="2.7" fill={color} />
      {/* tiny lash above open eye */}
      <path
        d="M22.5 10.5 L22.5 8.5"
        stroke={color} strokeWidth="2"
        strokeLinecap="round"
      />
    </svg>
  );
}

// ============================================================
// C. Wink Keycap — product-metaphor version. Rounded keycap
//    silhouette with the wink face inside. Ties to shortcuts.
// ============================================================
function Logo_WinkKeycap({ size = 64, color = 'currentColor', bg }) {
  const sw = 2;
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <rect
        x="4.5" y="4.5" width="23" height="23" rx="5.5"
        stroke={color} strokeWidth={sw} fill={bg || 'none'}
      />
      {/* closed eye — concave-up */}
      <path
        d="M9 14.5 Q 12.5 18, 16 14.5"
        stroke={color} strokeWidth="2.2"
        strokeLinecap="round" fill="none"
      />
      {/* open eye */}
      <circle cx="21.5" cy="16.5" r="2.2" fill={color} />
    </svg>
  );
}

// ============================================================
// D. Wink W — monogram. The W's second valley is replaced with a
//    soft U curve, visually "winking" compared to the rest.
//    Designed to work as both icon and wordmark initial.
// ============================================================
function Logo_WinkW({ size = 64, color = 'currentColor' }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      {/* angular left three strokes: V-V with shared apex at center */}
      <path
        d="M4 8 L9.5 24 L14.5 13 L16.5 13"
        stroke={color} strokeWidth="2.6"
        strokeLinecap="round" strokeLinejoin="round" fill="none"
      />
      {/* soft right half: U-curve (the wink) + angular rise */}
      <path
        d="M16.5 13 Q 19 27, 22.5 22 L 28 8"
        stroke={color} strokeWidth="2.6"
        strokeLinecap="round" strokeLinejoin="round" fill="none"
      />
    </svg>
  );
}

// ============================================================
// E. Wink Dot-i — typographic. Lowercase "i" whose tittle is a
//    winking crescent. Pairs with the wordmark.
//    Redesigned so the tittle curves UP (smiling eye).
// ============================================================
function Logo_WinkDotI({ size = 64, color = 'currentColor' }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      {/* stem */}
      <path
        d="M16 13.5 L16 25"
        stroke={color} strokeWidth="3.6"
        strokeLinecap="round"
      />
      {/* winking tittle: concave-up closed eye */}
      <path
        d="M11.5 5 Q 16 10, 20.5 5"
        stroke={color} strokeWidth="3"
        strokeLinecap="round" fill="none"
      />
    </svg>
  );
}

// ============================================================
// F. Wink Pair — a pair of full-oval eyes, left one partially
//    closed (the classic 😉 "half-moon"). Reads as literal eyes
//    in a face, works well as a system tray icon.
// ============================================================
function Logo_WinkPair({ size = 64, color = 'currentColor' }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      {/* left eye: half-closed (lid from above covers top half) */}
      <path
        d="M6 16 Q 10.5 11.5, 15 16 Q 10.5 18, 6 16 Z"
        fill={color}
      />
      {/* right eye: full open oval */}
      <ellipse cx="22" cy="16" rx="3" ry="3.6" fill={color} />
    </svg>
  );
}

// ---------- Wordmark ----------
// Typeset "Wink" in SF Pro-ish style with the i replaced by the dot-i
// winking glyph. Used in the menubar header + splash + updates card.
function Wordmark({ size = 20, color = 'currentColor' }) {
  const h = size;
  const stroke = Math.max(1.5, h * 0.11);
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'baseline', gap: 0,
      fontFamily: window.SF,
      fontSize: h,
      fontWeight: 600,
      color,
      letterSpacing: -0.5,
      lineHeight: 1,
    }}>
      <span>W</span>
      <span style={{ position: 'relative', display: 'inline-block', width: h * 0.35, height: h }}>
        {/* i stem */}
        <span style={{
          position: 'absolute', left: '50%', top: h * 0.25,
          transform: 'translateX(-50%)',
          width: stroke, height: h * 0.7,
          background: color, borderRadius: stroke,
        }} />
        {/* winking tittle */}
        <svg
          style={{ position: 'absolute', left: '50%', top: -h * 0.02, transform: 'translateX(-50%)' }}
          width={h * 0.44} height={h * 0.28} viewBox="0 0 16 10" fill="none"
        >
          <path d="M2 3 Q 8 9, 14 3" stroke={color} strokeWidth="2.4" strokeLinecap="round" fill="none" />
        </svg>
      </span>
      <span>nk</span>
    </span>
  );
}

Object.assign(window, {
  Logo_WinkTwin,
  Logo_WinkLash,
  Logo_WinkKeycap,
  Logo_WinkW,
  Logo_WinkDotI,
  Logo_WinkPair,
  Wordmark,
  // Alias for backward compat with menubar/general chrome that references
  // Logo_WinkCrescent — now points to the fixed Twin mark.
  Logo_WinkCrescent: Logo_WinkTwin,
});
