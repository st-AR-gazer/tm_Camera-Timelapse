const float TAU = 6.28318530717958647692;

void Main() {
    PathCam::RefreshFiles();
}

void Update(float dt) {
    PathCam::g_Player.Update(dt / 1000.0f);
}