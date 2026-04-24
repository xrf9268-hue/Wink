// Main window — combines sidebar + one of the three tabs.

function MainWindow({ theme = 'light', tab = 'shortcuts', permissionGranted = false, width = 820, height = 640 }) {
  const t = theme === 'dark' ? window.darkTheme : window.lightTheme;
  return (
    <window.WinChrome t={t} width={width} height={height} title="Wink">
      <window.Sidebar t={t} active={tab} />
      <div style={{
        flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column',
        background: t.windowBg,
      }}>
        {tab === 'shortcuts' && <window.ShortcutsTab theme={theme} permissionGranted={permissionGranted} />}
        {tab === 'general' && <window.GeneralTab theme={theme} />}
        {tab === 'insights' && <window.InsightsTab theme={theme} />}
      </div>
    </window.WinChrome>
  );
}

Object.assign(window, { MainWindow });
