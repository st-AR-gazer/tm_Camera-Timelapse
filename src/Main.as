const float TAU = 6.28318530717958647692;

void Main() {
    PathCam::RefreshFiles();
    PathCam::g_Player.snapToFps = S_DefaultSnapToFps;
    PathCam::g_Player.rate = S_DefaultRate;
}

void Update(float dt) {
    PathCam::g_Player.Update(dt / 1000.0f);
}

void Render() {
    FILE_EXPLORER_BASE_RENDERER();
}