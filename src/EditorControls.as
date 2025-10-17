namespace Editor {
    void EnableCustomCameraInputs() {
        auto editor = cast<CGameCtnEditorFree>(GetApp().Editor);
        if (editor is null) return;

        editor.PluginMapType.EnableEditorInputsCustomProcessing = true;
        editor.PluginMapType.Camera.IgnoreCameraCollisions(true);

        const float big = Math::PI * 2.0f * 100.0f;
        editor.OrbitalCameraControl.m_MaxVAngle = big;
        editor.OrbitalCameraControl.m_MinVAngle = -big;
    }

    void DisableCustomCameraInputs() {
        auto editor = cast<CGameCtnEditorFree>(GetApp().Editor);
        if (editor is null) return;
        editor.PluginMapType.EnableEditorInputsCustomProcessing = false;
    }

    void SetTargetedPosition(const vec3 &in pos) {
        auto editor = cast<CGameCtnEditorFree>(GetApp().Editor);
        if (editor is null) return;
        editor.PluginMapType.CameraTargetPosition = pos;
    }

    void SetTargetedDistance(float dist) {
        auto editor = cast<CGameCtnEditorFree>(GetApp().Editor);
        if (editor is null) return;
        editor.PluginMapType.CameraToTargetDistance = dist;
    }

    void SetOrbitalAngle(float h, float v) {
        auto editor = cast<CGameCtnEditorFree>(GetApp().Editor);
        if (editor is null) return;
        editor.PluginMapType.CameraHAngle = h;
        editor.PluginMapType.CameraVAngle = v;
    }
}
