// Wink logo marks — revised round.
// Fixing the frown problem: closed eyes must curve UPWARD (like the 😉
// crescent), not down. A downward arc reads as a mouth, and a sad one.
//
// All marks use currentColor so they can template for the macOS menubar.

// ============================================================
// 1. WinkCrescent — Apple product-style redesign.
//
// Construction (on a 32-unit grid, mirroring how Apple builds system
// marks like the Apple logo, Siri orb, moon/Focus glyphs):
//
//   • The crescent is the BOOLEAN SUBTRACTION of two perfect circles.
//       - Outer disc:  r = 9,  centered at (12, 16)
//       - Cutter disc: r = 8,  centered at (15.2, 13.4)
//     The offset is set so the crescent's thickest point equals the
//     diameter of the open eye — both shapes carry the same optical
//     weight. Built via even-odd fill-rule, not a hand-tuned bezier.
//
//   • The open eye is a true circle, r = 2.2, at (25, 16). It sits on
//     the same optical baseline (y=16) as the crescent's vertical
//     center. Diameter (4.4) ≈ crescent waist (4.4). Intentional.
//
//   • The whole mark is inset from the 32-grid edges by the standard
//     Apple icon keyline (≈ 3u), leaving the 26u safe area that scales
//     cleanly into a squircle tile.
//
// Two renderings share the same geometry:
//   - `variant="flat"`  → single-color, template-tintable (menu bar,
//                          wordmark, small sizes). Default.
//   - `variant="dimensional"` → soft inner highlight + outer glow,
//                          for the app-icon tile. Light source top-left,
//                          ~20% highlight, ~8% contact shadow. No
//                          skeuomorphic bevel — just optical lift.
// ============================================================
function Logo_WinkCrescent({
  size = 64,
  color = 'currentColor',
  variant = 'flat',
  idPrefix = 'wc',
}) {
  // Unique ids so multiple instances on one page don't collide.
  const uid = React.useMemo(
    () => `${idPrefix}-${Math.random().toString(36).slice(2, 8)}`,
    [idPrefix]
  );

  // Crescent path: outer circle minus inner (cutter) circle.
  // Written as two sub-paths with opposite winding + evenodd fill.
  //   Outer: circle at (12,16), r=9
  //   Inner: circle at (15.2, 13.4), r=8
  const crescentD =
    // outer circle (clockwise)
    'M12 7 a9 9 0 1 0 0 18 a9 9 0 1 0 0 -18 Z ' +
    // cutter (counter-clockwise → evenodd punches a hole)
    'M15.2 5.4 a8 8 0 1 1 0 16 a8 8 0 1 1 0 -16 Z';

  if (variant === 'dimensional') {
    return (
      <svg width={size} height={size} viewBox="0 0 32 32">
        <defs>
          {/* subtle top-left highlight across both shapes */}
          <linearGradient id={`${uid}-grad`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#ffffff" stopOpacity="0.22" />
            <stop offset="1" stopColor="#ffffff" stopOpacity="0" />
          </linearGradient>
          <radialGradient id={`${uid}-specular`} cx="0.35" cy="0.25" r="0.6">
            <stop offset="0" stopColor="#ffffff" stopOpacity="0.55" />
            <stop offset="0.6" stopColor="#ffffff" stopOpacity="0" />
          </radialGradient>
        </defs>

        {/* base fill */}
        <g fill={color}>
          <path d={crescentD} fillRule="evenodd" />
          <circle cx="25" cy="16" r="2.2" />
        </g>
        {/* top highlight wash */}
        <g style={{ mixBlendMode: 'screen' }}>
          <path d={crescentD} fillRule="evenodd" fill={`url(#${uid}-grad)`} />
          <circle cx="25" cy="16" r="2.2" fill={`url(#${uid}-grad)`} />
        </g>
        {/* specular on the crescent's belly */}
        <path
          d={crescentD}
          fillRule="evenodd"
          fill={`url(#${uid}-specular)`}
          style={{ mixBlendMode: 'screen' }}
        />
      </svg>
    );
  }

  // Flat variant — templateable single color.
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill={color}>
      <path d={crescentD} fillRule="evenodd" />
      <circle cx="25" cy="16" r="2.2" />
    </svg>
  );
}

// ============================================================
// 2. WinkFace — the strongest from round 1. Keep, but polish:
//    slit and oval get closer to "eye" proportions, and baseline
//    aligned so it reads as a face row.
// ============================================================
function Logo_WinkFace({ size = 64, color = 'currentColor' }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      {/* closed eye: soft curved slit so it reads as smiling-closed,
          not frowning-closed. */}
      <path
        d="M7 17 Q 11 15.3, 15 17"
        stroke={color} strokeWidth="2.6" strokeLinecap="round" fill="none"
      />
      {/* open eye */}
      <ellipse cx="22" cy="16" rx="2.6" ry="3.4" fill={color} />
    </svg>
  );
}

// ============================================================
// 3. WinkW — redo. The W is made of four strokes; the second-from-
//    right peak becomes a soft curve (the wink), while the rest stays
//    angular. At small sizes the curve is still a peak; it just
//    reads as a subtle variation.
// ============================================================
function Logo_WinkW({ size = 64, color = 'currentColor', stroke = 2.6 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      {/* left half: angular V */}
      <path
        d="M5 9 L10 23 L16 13"
        stroke={color} strokeWidth={stroke}
        strokeLinecap="round" strokeLinejoin="round" fill="none"
      />
      {/* right half: soft curved V — the wink */}
      <path
        d="M16 13 Q 19 28, 22 23 Q 24.5 20, 27 9"
        stroke={color} strokeWidth={stroke}
        strokeLinecap="round" strokeLinejoin="round" fill="none"
      />
    </svg>
  );
}

// ============================================================
// 4. WinkKeycap — rounded keycap with a tiny wink face stamped on it.
//    The face uses a crescent + dot (crescent curves up, happy).
//    Ties to the "shortcut key" product metaphor.
// ============================================================
function Logo_WinkKeycap({ size = 64, color = 'currentColor', stroke = 1.9, bg }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      <rect
        x="5.5" y="5.5" width="21" height="21" rx="5.5"
        stroke={color} strokeWidth={stroke} fill={bg || 'none'}
      />
      {/* crescent closed eye */}
      <path
        d="M10 17 Q 13 15.3, 16 17"
        stroke={color} strokeWidth={stroke * 1.2}
        strokeLinecap="round" fill="none"
      />
      {/* open eye */}
      <circle cx="20.5" cy="16" r={stroke * 1.25} fill={color} />
    </svg>
  );
}

// ============================================================
// 5. WinkDotI — typographic: a lowercase "i" where the tittle (dot)
//    is replaced with a small crescent, like the i is winking.
//    Great as a textmark; works inline with the wordmark "W·nk".
// ============================================================
function Logo_WinkDotI({ size = 64, color = 'currentColor', stroke = 3.4 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      {/* stem */}
      <path
        d="M16 13 L16 25"
        stroke={color} strokeWidth={stroke}
        strokeLinecap="round"
      />
      {/* winking tittle: crescent */}
      <path
        d="M12.5 8.5 Q 16 6.5, 19.5 8.5"
        stroke={color} strokeWidth={stroke * 0.85}
        strokeLinecap="round" fill="none"
      />
    </svg>
  );
}

// ============================================================
// 6. WinkLashes — two downward-sweeping lashes above a pair of eyes;
//    left is closed (lash touches baseline), right is open (lash +
//    dot). More illustrated/friendly; still geometric.
// ============================================================
function Logo_WinkLashes({ size = 64, color = 'currentColor', stroke = 2.2 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      {/* left closed eye: wide crescent on baseline */}
      <path
        d="M6 18 Q 10 14, 14 18"
        stroke={color} strokeWidth={stroke}
        strokeLinecap="round" fill="none"
      />
      {/* right open eye */}
      <circle cx="22" cy="17" r="2.4" fill={color} />
      {/* tiny lash above right eye for asymmetry */}
      <path
        d="M22 12 L22 10"
        stroke={color} strokeWidth={stroke * 0.9}
        strokeLinecap="round"
      />
    </svg>
  );
}

Object.assign(window, {
  Logo_WinkCrescent,
  Logo_WinkFace,
  Logo_WinkW,
  Logo_WinkKeycap,
  Logo_WinkDotI,
  Logo_WinkLashes,
});
