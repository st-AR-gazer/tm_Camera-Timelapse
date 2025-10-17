const float TAU = 6.28318530717958647692;

void Main() {
    PathCam::RefreshFiles();
    PathCam::g_Player.snapToFps = S_DefaultSnapToFps;
    PathCam::g_Player.rate = S_DefaultRate;
}

bool wasInEditor = false;
void Update(float dt) {
    PathCam::g_Player.Update(dt / 1000.0f);
    PathCam::UpdateAutosaveTick();

    bool isInEditor = cast<CGameCtnEditorFree>(GetApp().Editor) !is null;
    if (wasInEditor && !isInEditor) {
        PathCam::OnEditorExit();
        wasInEditor = false;
    }
    if (isInEditor) wasInEditor = true;
}

void Render() {
    FILE_EXPLORER_BASE_RENDERER();
}