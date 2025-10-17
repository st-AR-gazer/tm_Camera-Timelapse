namespace PathCam {

    class Player {
        CameraPath path;
        bool loaded = false;
        bool playing = false;

        float time = 0.0;
        float rate = 1.0;

        int frameIndex = 0;
        bool snapToFps = true;

        bool _warnedModeMismatch = false;
        bool _warnedNoData = false;

        bool  _blendActive = false;
        float _blendElapsed = 0.0;
        float _blendDuration = 0.0;
        CamKey _blendFrom;
        CamKey _blendTo;

        bool _haveLastApplied = false;
        CamKey _lastApplied;

        Player() { Reset(); }

        void Reset() {
            time = 0.0;
            frameIndex = 0;
            playing = false;
            _blendActive = false;
            _blendElapsed = 0.0;
            _blendDuration = 0.0;
            _haveLastApplied = false;
            _warnedModeMismatch = false;
            _warnedNoData = false;
        }

        void LoadFromFile(const string &in fileOrRel) {
            CameraPath p;
            bool ok = LoadPath(fileOrRel, p);
            log("Player.LoadFromFile: LoadPath returned " + tostring(ok), ok ? LogLevel::Info : LogLevel::Error, -1, "Player::LoadFromFile");

            if (!ok) { this.loaded = false; return; }

            float prevRate = rate;
            this.path   = p;
            this.loaded = true;

            if (S_PersistRate) {
                this.rate = prevRate;
            } else {
                this.rate = p.meta.speed;
                if (this.rate <= 0.0) this.rate = 1.0;
            }

            Reset();

            Seek(this.path.meta.startOffset);
            log("LoadFromFile: sought to startOffset=" + Text::Format("%.3f", this.path.meta.startOffset) + " (mode=" + (this.path.mode==PathMode::Fn ? "fn" : "keyframes") + ")", LogLevel::Info, -1, "Player::LoadFromFile");
        }

        void Seek(float t) {
            if (!loaded) return;

            float dur = Duration();
            if (path.meta.loop && dur > 0.0) {
                t = t - dur * Math::Floor(t / dur);
                if (t < 0.0) t += dur;
            } else {
                t = Math::Clamp(t, 0.0, dur);
            }

            time = t;
            frameIndex = (path.meta.fps > 0.0 ? int(Math::Round(time * path.meta.fps)) : 0);

            CamKey k = EvaluateAt(time);

            auto editor = cast<CGameCtnEditorFree>(GetApp().Editor);
            bool hadCustomProc = false;
            if (editor !is null) {
                hadCustomProc = editor.PluginMapType.EnableEditorInputsCustomProcessing;
            }

            bool tempEnabled = false;
            if (editor !is null && !hadCustomProc) {
                Editor::EnableCustomCameraInputs();
                tempEnabled = true;
            }

            Editor::SetTargetedDistance(k.dist);
            Editor::SetTargetedPosition(k.target);
            Editor::SetOrbitalAngle(k.h, k.v);

            if (tempEnabled && !playing) {
                Editor::DisableCustomCameraInputs();
            }

            _lastApplied = k;
            _haveLastApplied = true;
            _blendActive = false;

            // log("Seek: t=" + Text::Format("%.3f", t) + " target=" + tostring(k.target) + " dist=" + Text::Format("%.2f", k.dist) + " h=" + Text::Format("%.3f", k.h) + " v=" + Text::Format("%.3f", k.v), LogLevel::Debug, -1, "Player::Seek");
        }

        void Play() {
            if (!loaded) { log("Play() called but no path loaded", LogLevel::Warn, 64, "Play"); return; }
            playing = true;
            Editor::EnableCustomCameraInputs();
        }

        void Pause() {
            playing = false;
            Editor::DisableCustomCameraInputs();
        }

        void Stop() {
            playing = false;
            Editor::DisableCustomCameraInputs();
            Reset();
        }

        float Duration() const {
            return Math::Max(0.0, path.meta.duration);
        }

        CamKey LerpCamKey(const CamKey &in a, const CamKey &in b, float u) {
            CamKey r;
            r.t = Math::Lerp(a.t, b.t, u);
            r.target = Math::Lerp(a.target, b.target, u);
            r.dist = Math::Lerp(a.dist, b.dist, u);
            r.h = AngleLerp(a.h, b.h, u);
            r.v = AngleLerp(a.v, b.v, u);
            return r;
        }

        CamKey EvaluateAt(float t) {
            bool hasFn = path.fnName.Length > 0;
            bool hasKeys = path.keys.Length > 0;

            if (path.mode == PathMode::Fn && hasFn) {
                return EvalFn(path, t);
            }
            if (path.mode == PathMode::Keyframes && hasKeys) {
                return EvalKeyframes(path, t);
            }

            if (hasFn) {
                if (S_WarnModeMismatchOnce && !_warnedModeMismatch) { _warnedModeMismatch = true; log("EvaluateAt: mode mismatch; falling back to fn='" + path.fnName + "'", LogLevel::Warn, 126, "Seek"); }
                return EvalFn(path, t);
            }
            if (hasKeys) {
                if (S_WarnModeMismatchOnce && !_warnedModeMismatch) { _warnedModeMismatch = true; log("EvaluateAt: mode mismatch; falling back to keyframes", LogLevel::Warn, 130, "Seek"); }
                return EvalKeyframes(path, t);
            }

            if (!_warnedNoData) { _warnedNoData = true; log("EvaluateAt: no fn and no keyframes available; returning safe frame", LogLevel::Error, 134, "Seek"); }

            CamKey safe;
            safe.t = t;
            safe.target = vec3(0, 0, 0);
            safe.dist = 200.0;
            safe.h = 0.0;
            safe.v = 0.0;
            return safe;
        }

        void BeginBlendTo(const CamKey &in next) {
            float durMs = Math::Max(0.0, S_StepBlendMs);
            float dur = durMs / 1000.0;
            if (dur <= 0.0 || !_haveLastApplied) {
                Editor::SetTargetedDistance(next.dist);
                Editor::SetTargetedPosition(next.target);
                Editor::SetOrbitalAngle(next.h, next.v);
                _lastApplied = next;
                _haveLastApplied = true;
                _blendActive = false;
                _blendElapsed = 0.0;
                _blendDuration = 0.0;
                return;
            }

            _blendFrom = _lastApplied;
            _blendTo = next;
            _blendDuration = dur;
            _blendElapsed = 0.0;
            _blendActive = true;
        }

        void ApplyPose(const CamKey &in k) {
            Editor::SetTargetedDistance(k.dist);
            Editor::SetTargetedPosition(k.target);
            Editor::SetOrbitalAngle(k.h, k.v);
            _lastApplied = k;
            _haveLastApplied = true;
        }

        void Update(float dt) {
            if (!loaded || !playing) return;

            time += dt * rate;

            float dur = Duration();
            if (path.meta.loop && dur > 0.0) {
                time = time - dur * Math::Floor(time / dur);
                if (time < 0.0) time += dur;
            } else {
                time = Math::Clamp(time, 0.0, dur);
            }

            bool quantize = (path.mode == PathMode::Keyframes && snapToFps && path.meta.fps > 0.0);

            if (quantize) {
                if (S_SnapInterpolate) {
                    float fps = Math::Max(0.0001, path.meta.fps);
                    float ft  = time * fps;
                    int   f0  = int(Math::Floor(ft));
                    float u   = ft - float(f0);

                    float t0 = float(f0) / fps;
                    float t1 = float(f0 + 1) / fps;

                    if (path.meta.loop && dur > 0.0) {
                        t0 = WrapTime(t0, dur);
                        t1 = WrapTime(t1, dur);
                    } else {
                        t0 = Math::Clamp(t0, 0.0, dur);
                        t1 = Math::Clamp(t1, 0.0, dur);
                    }

                    CamKey k0 = EvaluateAt(t0);
                    CamKey k1 = EvaluateAt(t1);
                    CamKey k  = LerpCamKey(k0, k1, u);
                    ApplyPose(k);
                    _blendActive = false;
                    frameIndex = f0;
                } else {
                    if (_blendActive) {
                        _blendElapsed += dt;
                        float denom = Math::Max(0.000001, _blendDuration);
                        float u = Math::Clamp(_blendElapsed / denom, 0.0, 1.0);
                        CamKey k = LerpCamKey(_blendFrom, _blendTo, u);
                        ApplyPose(k);
                        if (u >= 1.0) _blendActive = false;
                    }

                    int targetFrame = int(Math::Floor(time * path.meta.fps + 0.00001));
                    if (targetFrame != frameIndex) {
                        frameIndex = targetFrame;
                        float tSnap = float(frameIndex) / path.meta.fps;
                        CamKey next = EvaluateAt(tSnap);
                        BeginBlendTo(next);
                    }
                }
            } else {
                CamKey k = EvaluateAt(time);
                ApplyPose(k);
                _blendActive = false;
            }
        }

    }

}
