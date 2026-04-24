// Wink logo marks — revised round.
// Fixing the frown problem: closed eyes must curve UPWARD (like the 😉
// crescent), not down. A downward arc reads as a mouth, and a sad one.
//
// All marks use currentColor so they can template for the macOS menubar.

// ============================================================
// 1. WinkCrescent — the iconic wink: closed-eye crescent + open dot.
//    Redesigned for menu-bar / small sizes:
//    - Crescent is thicker and taller (a proper crescent, not a sliver)
//    - Positioned to fill the viewBox top-to-bottom
//    - Dot is sized to match crescent stroke, placed at the crescent's tip
//    This reads as a single glyph (like 😉 compressed), not two specks.
// ============================================================
function Logo_WinkCrescent({ size = 64, color = 'currentColor' }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      {/* Closed eye: fat crescent filling most of the vertical space.
          Built as a lens between two arcs — top arc concave (smile),
          bottom arc convex. Creates a bold, unmistakable eye shape. */}
      <path
        d="M4 11
           Q 11.5 22, 19 11
           Q 11.5 16, 4 11 Z"
        fill={color}
      />
      {/* Open eye: a solid pill, same optical weight as the crescent's
          thickest point, aligned on its vertical center. */}
      <ellipse cx="25" cy="15.5" rx="2.8" ry="3.4" fill={color} />
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
