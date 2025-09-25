// PathIO.as
// Loading JSON, unit conversion, folder listing

namespace PathCam {

    string PathsDir() {
        string p = IO::FromStorageFolder("paths");
        if (!IO::FolderExists(p)) IO::CreateFolder(p);
        return p;
    }

    array<string> ListPathFiles() {
        string dir = PathsDir();
        auto entries = IO::IndexFolder(dir, false); // absolute or full-ish paths (implementation-dependent)
        array<string> files;
        for (uint i = 0; i < entries.Length; i++) {
            string fullPath = entries[i];
            string fileOnly = Path::GetFileName(fullPath);
            if (fileOnly.EndsWith(".json") && fileOnly.StartsWith("path.")) {
                files.InsertLast(fullPath); // keep absolute; loader is robust now
            }
        }
        files.SortAsc();
        return files;
    }


    vec3 CoordToPosBlocks(const vec3 &in bc) {
        return vec3(bc.x * 32.0, (int(bc.y) - 8) * 8.0, bc.z * 32.0);
    }

    bool ReadFloat(const Json::Value@ v, const string &in key, float &out dst, float def=0.0) {
        dst = def;
        if (v is null) return false;
        auto @x = v.Get(key);
        if (x is null || x.GetType() == Json::Type::Null) return false;

        // If it's a string, parse it (handles "60" / "60.0")
        if (x.GetType() == Json::Type::String) {
            string s = string(x);
            float val = Text::ParseFloat(s);
            dst = val;
            return true;
        }

        // Otherwise, assume numeric-convertible (int/float)
        dst = float(x);
        return true;
    }

    bool ReadBool(const Json::Value@ v, const string &in key, bool &out dst, bool def=false) {
        dst = def;
        if (v is null) return false;
        auto @x = v.Get(key);
        if (x is null || x.GetType() == Json::Type::Null) return false;

        Json::Type t = x.GetType();

        // 1) Proper JSON boolean
        if (t == Json::Type::Boolean) {
            dst = bool(x);
            return true;
        }

        // 2) Numeric: treat any non-zero as true
        if (t == Json::Type::Number) {
            float val = float(x);          // works for int/float Json numbers
            dst = (val != 0.0f);
            return true;
        }

        // 3) String forms: true/false, yes/no, on/off, 1/0
        if (t == Json::Type::String) {
            string s = string(x);
            s = s.Trim().ToLower();
            if (s == "true" || s == "1" || s == "yes" || s == "y" || s == "on")  { dst = true;  return true; }
            if (s == "false"|| s == "0" || s == "no"  || s == "n" || s == "off") { dst = false; return true; }
            return false; // unrecognized string
        }

        // Other types: keep default
        return false;
    }



    bool ReadString(const Json::Value@ v, const string &in key, string &out dst, const string &in def="") {
        if (v is null) { dst = def; return false; }
        auto @x = v.Get(key);
        if (x is null || x.GetType() == Json::Type::Null) { dst = def; return false; }
        dst = string(x);
        return true;
    }

    bool ReadVec3(const Json::Value@ v, const string &in key, vec3 &out dst) {
        if (v is null) return false;
        auto @a = v.Get(key);
        if (a is null || a.GetType() != Json::Type::Array || a.Length < 3) return false;
        dst = vec3(float(a[0]), float(a[1]), float(a[2]));
        return true;
    }

    void ParseMetadata(const Json::Value@ md, PathMetadata &out meta) {
        if (md is null) return;
        ReadFloat(md, "fps", meta.fps, meta.fps);
        ReadFloat(md, "duration", meta.duration, meta.duration);
        ReadBool(md, "loop", meta.loop, meta.loop);
        ReadFloat(md, "speed", meta.speed, meta.speed);
        string interp = "catmullrom";
        ReadString(md, "interpolation", interp, interp);
        meta.interp = interp.ToLower().StartsWith("lin") ? InterpMode::Linear : InterpMode::CatmullRom;
        string units = "world";
        ReadString(md, "units", units, units);
        meta.unitsBlocks = units.ToLower().StartsWith("block");
    }

    vec3 AsWorld(const PathMetadata &in meta, const vec3 &in v) {
        return meta.unitsBlocks ? CoordToPosBlocks(v) : v;
    }

    // simple insertion sort by keyframe time (stable and tiny)
    void SortKeysByTime(array<CamKey> &inout ks) {
        for (uint i = 1; i < ks.Length; i++) {
            CamKey k = ks[i];
            int j = i - 1;
            while (j >= 0 && ks[uint(j)].t > k.t) {
                ks[uint(j + 1)] = ks[uint(j)];
                j--;
            }
            ks[uint(j + 1)] = k;
        }
    }

    // Load a normalized float curve: keys are [u, value] with u in [0..1] (wraps).
    bool LoadFloatCurve(const Json::Value@ parent, const string &in key, FloatCurve &out curve) {
        curve.keys.RemoveRange(0, curve.keys.Length);
        if (parent is null) return false;
        auto @arr = parent.Get(key);
        if (arr is null || arr.GetType() != Json::Type::Array) return false;

        for (uint i = 0; i < arr.Length; i++) {
            auto @e = arr[i];
            if (e is null) continue;

            FloatKey k;
            if (e.GetType() == Json::Type::Array && e.Length >= 2) {
                k.u = float(e[0]);
                k.v = float(e[1]);
            } else if (e.GetType() == Json::Type::Object) {
                // prefer "u" (normalized). If only "t" provided, we can't normalize here, so skip with a warning.
                bool haveU = ReadFloat(e, "u", k.u, -1.0f);
                if (!haveU) {
                    log("LoadFloatCurve: object key without 'u' not supported; use [u,value] pairs.", LogLevel::Warn, -1, "PathCam::LoadFloatCurve");
                    continue;
                }
                ReadFloat(e, "value", k.v, 0.0f);
            } else {
                continue;
            }

            // sanitize u
            if (Math::IsInf(k.u)) k.u = 0.0f;
            curve.keys.InsertLast(k);
        }

        if (curve.keys.Length == 0) return false;
        curve.SortByU();
        return true;
    }

    bool LoadPolylinePoints(const Json::Value@ parent, const string &in key, const PathMetadata &in meta, array<vec3> &out outPts) {
        outPts.RemoveRange(0, outPts.Length);
        if (parent is null) return false;
        auto @arr = parent.Get(key);
        if (arr is null || arr.GetType() != Json::Type::Array) return false;
        for (uint i = 0; i < arr.Length; i++) {
            auto @p = arr[i];
            if (p is null || p.GetType() != Json::Type::Array || p.Length < 3) continue;
            vec3 v = vec3(float(p[0]), float(p[1]), float(p[2]));
            v = AsWorld(meta, v);
            outPts.InsertLast(v);
        }
        return outPts.Length >= 2;
    }

    bool LoadKeyframes(const Json::Value@ root, CameraPath &out path) {
        auto @arr = root.Get("keyframes");
        if (arr is null || arr.GetType() != Json::Type::Array) return false;
        path.keys.RemoveRange(0, path.keys.Length);

        for (uint i = 0; i < arr.Length; i++) {
            auto @kf = arr[i];
            CamKey k;
            ReadFloat(kf, "t", k.t, 0.0);

            vec3 tgt;
            if (ReadVec3(kf, "target", tgt)) {
                k.target = AsWorld(path.meta, tgt);
            }

            ReadFloat(kf, "dist", k.dist, 200.0);

            auto @ang = kf.Get("angles_deg");
            if (ang !is null && ang.GetType() == Json::Type::Array && ang.Length >= 2) {
                k.h = float(ang[0]) * DEG2RAD;
                k.v = float(ang[1]) * DEG2RAD;
            } else {
                k.h = 0.0; k.v = 0.0;
            }

            path.keys.InsertLast(k);
        }

        SortKeysByTime(path.keys);

        // If duration missing, infer from last key
        if (path.meta.duration <= 0.0 && path.keys.Length > 0) {
            path.meta.duration = path.keys[path.keys.Length - 1].t;
        }
        return path.keys.Length > 0;
    }

    void LoadFn(const Json::Value@ root, CameraPath &out path) {
        auto @f = root.Get("fn");
        if (f is null || f.GetType() != Json::Type::Object) return;
        ReadString(f, "name", path.fnName, path.fnName);
        string n = path.fnName.ToLower();

        if (n == "orbital_circle") {
            ReadVec3(f, "center", path.fnCircle.center);
            path.fnCircle.center = AsWorld(path.meta, path.fnCircle.center);
            ReadFloat(f, "radius", path.fnCircle.radius, path.fnCircle.radius);
            ReadFloat(f, "v_deg", path.fnCircle.vDeg, path.fnCircle.vDeg);
            ReadFloat(f, "deg_per_sec", path.fnCircle.degPerSec, path.fnCircle.degPerSec);
            ReadFloat(f, "start_deg", path.fnCircle.startDeg, path.fnCircle.startDeg);
            ReadBool(f, "cw", path.fnCircle.cw, path.fnCircle.cw);

        } else if (n == "orbital_helix") {
            ReadVec3(f, "center", path.fnHelix.center);
            path.fnHelix.center = AsWorld(path.meta, path.fnHelix.center);
            ReadFloat(f, "radius", path.fnHelix.radius, path.fnHelix.radius);
            ReadFloat(f, "v_start_deg", path.fnHelix.vStartDeg, path.fnHelix.vStartDeg);
            ReadFloat(f, "v_end_deg", path.fnHelix.vEndDeg, path.fnHelix.vEndDeg);
            ReadFloat(f, "deg_per_sec", path.fnHelix.degPerSec, path.fnHelix.degPerSec);
            ReadFloat(f, "start_deg", path.fnHelix.startDeg, path.fnHelix.startDeg);
            ReadBool(f, "cw", path.fnHelix.cw, path.fnHelix.cw);

        } else if (n == "target_polyline") {
            // points + options
            LoadPolylinePoints(f, "points", path.meta, path.fnPolyline.pts);
            ReadBool(f, "closed", path.fnPolyline.closed, path.fnPolyline.closed);
            ReadFloat(f, "speed", path.fnPolyline.speed, path.fnPolyline.speed);
            ReadFloat(f, "dist", path.fnPolyline.dist, path.fnPolyline.dist);
            ReadFloat(f, "look_ahead", path.fnPolyline.lookAhead, path.fnPolyline.lookAhead);
            ReadFloat(f, "height_offset", path.fnPolyline.heightOffset, path.fnPolyline.heightOffset);
            string interp = "catmullrom";
            ReadString(f, "interpolation", interp, interp);
            path.fnPolyline.interp = interp.ToLower().StartsWith("lin") ? InterpMode::Linear : InterpMode::CatmullRom;

            // NEW: optional per-progress curves
            LoadFloatCurve(f, "height_offset_keys", path.fnPolyline.heightCurve);
            LoadFloatCurve(f, "dist_keys", path.fnPolyline.distCurve);
            LoadFloatCurve(f, "look_ahead_keys", path.fnPolyline.lookAheadCurve);

            path.fnPolyline.RebuildLengths();

            // Derive duration if missing and we have length+speed
            if (path.meta.duration <= 0.0f && path.fnPolyline.speed > 0.0f && path.fnPolyline.totalLen > 0.0f) {
                path.meta.duration = path.fnPolyline.totalLen / path.fnPolyline.speed;
                log("LoadPath: derived duration from polyline length: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, -1, "PathCam::LoadFn");
            }

        } else if (n == "moving_orbit") {
            // NEW: orbit around a moving center that follows its own polyline
            // center path
            LoadPolylinePoints(f, "center_points", path.meta, path.fnMovingOrbit.center.pts);
            // allow either "center_closed" (preferred) or "closed" as a fallback
            bool tmpClosed;
            if (ReadBool(f, "center_closed", tmpClosed, path.fnMovingOrbit.center.closed)) {
                path.fnMovingOrbit.center.closed = tmpClosed;
            } else {
                ReadBool(f, "closed", path.fnMovingOrbit.center.closed, path.fnMovingOrbit.center.closed);
            }
            ReadFloat(f, "center_speed", path.fnMovingOrbit.center.speed, path.fnMovingOrbit.center.speed);
            path.fnMovingOrbit.center.RebuildLengths();

            // orbit parameters
            ReadFloat(f, "radius", path.fnMovingOrbit.radius, path.fnMovingOrbit.radius);
            ReadFloat(f, "v_deg", path.fnMovingOrbit.vDeg, path.fnMovingOrbit.vDeg);
            ReadFloat(f, "deg_per_sec", path.fnMovingOrbit.degPerSec, path.fnMovingOrbit.degPerSec);
            ReadFloat(f, "start_deg", path.fnMovingOrbit.startDeg, path.fnMovingOrbit.startDeg);
            ReadBool(f, "cw", path.fnMovingOrbit.cw, path.fnMovingOrbit.cw);

            // optional curves along center progress
            LoadFloatCurve(f, "radius_keys", path.fnMovingOrbit.radiusCurve);
            LoadFloatCurve(f, "v_deg_keys", path.fnMovingOrbit.vDegCurve);

            // Derive duration, preferring center path cycle time
            if (path.meta.duration <= 0.0f) {
                if (path.fnMovingOrbit.center.speed > 0.0f && path.fnMovingOrbit.center.totalLen > 0.0f) {
                    path.meta.duration = path.fnMovingOrbit.center.totalLen / path.fnMovingOrbit.center.speed;
                    log("LoadPath: derived duration from moving_orbit center length: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, -1, "PathCam::LoadFn");
                } else {
                    float dps = Math::Abs(path.fnMovingOrbit.degPerSec);
                    if (dps > 0.0f) {
                        path.meta.duration = 360.0f / dps;
                        log("LoadPath: derived duration from moving_orbit deg_per_sec: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, -1, "PathCam::LoadFn");
                    }
                }
            }
        }
    }

    bool LoadPath(const string &in fileOrRel, CameraPath &out path) {
        // Resolve absolute path: accept either an absolute path or a filename relative to PathsDir()
        string abs = fileOrRel;
        if (!IO::FileExists(abs)) {
            string candidate = PathsDir() + "/" + fileOrRel;
            if (IO::FileExists(candidate)) abs = candidate;
        }

        if (!IO::FileExists(abs)) {
            log("LoadPath: not found '" + fileOrRel + "' (also looked in " + PathsDir() + ")", LogLevel::Error, -1, "PathCam::LoadPath");
            return false;
        }

        log("LoadPath: opening " + abs, LogLevel::Info, -1, "PathCam::LoadPath");

        IO::File f(abs, IO::FileMode::Read);
        string blob = f.ReadToEnd();
        f.Close();

        if (blob.Length == 0) {
            log("LoadPath: empty file: " + abs, LogLevel::Error, -1, "PathCam::LoadPath");
            return false;
        }

        auto @root = Json::Parse(blob);
        if (root is null || root.GetType() != Json::Type::Object) {
            log("LoadPath: JSON parse failed or root is not an object: " + abs, LogLevel::Error, -1, "PathCam::LoadPath");
            return false;
        }

        // Basic fields
        auto @ver = root.Get("version");
        if (ver !is null && ver.GetType() != Json::Type::Null) path.version = int(ver);

        ReadString(root, "name", path.name, ""); // may be empty; fallback below

        // Mode: keyframes (default) or fn
        string mode = "keyframes";
        ReadString(root, "mode", mode, mode);
        path.mode = mode.ToLower().StartsWith("fn") ? PathMode::Fn : PathMode::Keyframes;

        // Parse metadata (units, fps, duration, speed, interp, unitsBlocks, loop maybe)
        auto @md = root.Get("metadata");
        ParseMetadata(md, path.meta);

        // Allow duration at top-level as a fallback
        if (path.meta.duration <= 0.0) {
            float topDur;
            if (ReadFloat(root, "duration", topDur, -1.0) && topDur > 0.0) {
                path.meta.duration = topDur;
                log("LoadPath: using top-level duration=" + Text::Format("%.3f", topDur), LogLevel::Info, -1, "PathCam::LoadPath");
            }
        }

        // Load according to mode
        bool ok = false;
        if (path.mode == PathMode::Keyframes) {
            // Load keyframes into path.keys
            ok = LoadKeyframes(root, path);
            if (!ok) {
                log("LoadPath: no/invalid keyframes in " + abs, LogLevel::Error, -1, "PathCam::LoadPath");
                return false;
            }

            // If duration missing, infer from last keyframe
            if (path.meta.duration <= 0.0 && path.keys.Length > 0) {
                path.meta.duration = path.keys[path.keys.Length - 1].t;
                log("LoadPath: inferred duration from last keyframe: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, -1, "PathCam::LoadPath");
            }

            // Final validation for keyframes
            if (path.keys.Length == 0) {
                log("LoadPath: keyframes mode but keys.Length == 0", LogLevel::Error, -1, "PathCam::LoadPath");
                return false;
            }

            ok = true;
        } else {
            // Function mode: load fn payload into path.fn*
            LoadFn(root, path);

            // Accept duration inside fn block as a fallback (e.g., "fn": { "duration": 60 })
            if (path.meta.duration <= 0.0) {
                auto @fnObj = root.Get("fn");
                float fnDur;
                if (ReadFloat(fnObj, "duration", fnDur, -1.0) && fnDur > 0.0) {
                    path.meta.duration = fnDur;
                    log("LoadPath: used fn.duration=" + Text::Format("%.3f", fnDur) + "s", LogLevel::Info, -1, "PathCam::LoadPath");
                }
            }

            // If still missing, try to derive from known fn types
            if (path.meta.duration <= 0.0) {
                string fn = path.fnName.ToLower();
                if (fn == "orbital_circle") {
                    float dps = Math::Abs(path.fnCircle.degPerSec);
                    if (dps > 0.0) {
                        path.meta.duration = 360.0 / dps;
                        log("LoadPath: derived duration for orbital_circle: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, -1, "PathCam::LoadPath");
                    }
                } else if (fn == "orbital_helix") {
                    float dps = Math::Abs(path.fnHelix.degPerSec);
                    if (dps > 0.0) {
                        path.meta.duration = 360.0 / dps;
                        log("LoadPath: derived duration for orbital_helix: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, -1, "PathCam::LoadPath");
                    }
                } else if (fn == "target_polyline") {
                    if (path.fnPolyline.totalLen > 0.0 && path.fnPolyline.speed > 0.0) {
                        path.meta.duration = path.fnPolyline.totalLen / path.fnPolyline.speed;
                        log("LoadPath: derived duration from polyline length: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, -1, "PathCam::LoadPath");
                    }
                }
            }

            // Final validation for fn mode: require fnName and positive duration
            if (path.fnName.Length == 0) {
                log("LoadPath: fn-mode but no fn.name specified", LogLevel::Error, -1, "PathCam::LoadPath");
                return false;
            }
            if (path.meta.duration <= 0.0) {
                log("LoadPath: fn-mode requires metadata.duration>0 (or derivable), currently duration=" + Text::Format("%.3f", path.meta.duration), LogLevel::Error, -1, "PathCam::LoadPath");
                return false;
            }

            ok = true;
        }

        // ---- Resolve loop flag robustly (metadata > top-level > fn), case-safe ----
        bool loopVal = path.meta.loop;
        bool haveLoop = false;

        auto @mdObj   = root.Get("metadata");
        auto @fnObj   = root.Get("fn");
        bool tmpLoop;

        if (ReadBool(mdObj, "loop", tmpLoop, loopVal) || ReadBool(mdObj, "Loop", tmpLoop, loopVal)) {
            loopVal = tmpLoop;
            haveLoop = true;
        }

        if (!haveLoop && (ReadBool(root, "loop", tmpLoop, loopVal) || ReadBool(root, "Loop", tmpLoop, loopVal))) {
            loopVal = tmpLoop;
            haveLoop = true;
        }

        if (!haveLoop && (ReadBool(fnObj, "loop", tmpLoop, loopVal) || ReadBool(fnObj, "Loop", tmpLoop, loopVal))) {
            loopVal = tmpLoop;
            haveLoop = true;
        }

        path.meta.loop = loopVal;
        log("LoadPath: loop=" + (path.meta.loop ? "true" : "false") + (haveLoop ? "" : " (default)"), LogLevel::Info, -1, "PathCam::LoadPath");

        if (path.name.Length == 0) {
            string fileOnly = Path::GetFileName(abs);
            int dotIx = _Text::NthLastIndexOf(fileOnly, ".", 1);
            if (dotIx > 0) path.name = fileOnly.SubStr(0, dotIx); else path.name = fileOnly;
        }

        if (!ok) { log("LoadPath: final validation failed for " + abs, LogLevel::Error, -1, "PathCam::LoadPath"); return false; }
        log("LoadPath: loaded '" + path.name + "' (mode=" + (path.mode==PathMode::Keyframes ? "keyframes" : "fn") + ", duration=" + Text::Format("%.3f", path.meta.duration) + "s, fps=" + Text::Format("%.2f", path.meta.fps) + ")", LogLevel::Info, -1, "PathCam::LoadPath");

        return true;
    }

}
