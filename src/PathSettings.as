[Setting category="Camera" name="Step blend duration (ms)" min=0 max=2000]
float S_StepBlendMs = 250.0f;

[Setting category="Camera" name="Warn once on mode mismatch"]
bool S_WarnModeMismatchOnce = true;

[Setting category="Camera" name="Smooth when snapping to FPS (interpolate between frames)"]
bool S_SnapInterpolate = true;

[Setting hidden name="Default: Snap to FPS frames"]
bool S_DefaultSnapToFps = false;

// rate
[Setting category="Camera" name="Persist playback rate across loads"]
bool S_PersistRate = true;

[Setting category="Camera" name="Default playback rate"]
float S_DefaultRate = 1.0;

[Setting category="Camera" name="Rate slider max"]
float S_RateMax = 400.0;
[Setting category="Camera" name="Rate slider min"]
float S_RateMin = 0.01;

// persistence
[Setting category="Camera" name="Autosave progress every (s) (0 disables)" min=0 max=86400]
float S_AutoSaveEvery = 300.0;

[Setting category="Camera" name="Autosave when leaving the editor"]
bool S_AutoSaveOnEditorExit = true;

[Setting category="Camera" name="Include current Rate in profile when saving"]
bool S_SaveRateInProfile = false;

[Setting category="Camera" name="Make a backup before overwriting profile"]
bool S_BackupBeforeOverwrite = true;