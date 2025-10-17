namespace PathCam {

    enum InterpMode {
        Linear,
        CatmullRom
    }
    
    const float DEG2RAD = Math::PI / 180.0;
    const float TAU     = 6.28318530717958647692;

    class CamKey {
        float t;
        vec3  target;
        float dist;
        float h;
        float v;
    }

    class FloatKey {
        float u;
        float v;
    }

    class FloatCurve {
        array<FloatKey> keys;

        bool Has() const { return keys.Length > 0; }

        void SortByU() {
            for (uint i = 1; i < keys.Length; i++) {
                FloatKey k = keys[i];
                int j = i - 1;
                while (j >= 0 && keys[uint(j)].u > k.u) {
                    keys[uint(j + 1)] = keys[uint(j)];
                    j--;
                }
                keys[uint(j + 1)] = k;
            }
        }

        float Eval01(float u) const {
            if (keys.Length == 0) return 0.0f;
            if (keys.Length == 1) return keys[0].v;

            u = u - Math::Floor(u);
            uint last = keys.Length - 1;

            for (uint i = 0; i < last; i++) {
                float a = keys[i].u;
                float b = keys[i + 1].u;
                if (b < a) continue;
                if (u >= a && u <= b) {
                    float denom = (b - a) > 1e-6 ? (u - a) / (b - a) : 0.0f;
                    return Math::Lerp(keys[i].v, keys[i + 1].v, denom);
                }
            }

            float a = keys[last].u;
            float b = keys[0].u + 1.0f;
            float uu = (u >= a) ? u : (u + 1.0f);
            float denom = (b - a) > 1e-6 ? (uu - a) / (b - a) : 0.0f;
            return Math::Lerp(keys[last].v, keys[0].v, denom);
        }
    }

    class PathMetadata {
        float fps         = 1.0;
        float duration    = 0.0;
        bool loop         = false;
        float speed       = 1.0;
        InterpMode interp = InterpMode::CatmullRom;
        bool unitsBlocks  = false;
        float startOffset = 0.0;
    }

    class FnCircle {
        vec3 center     = vec3(0,0,0);
        float radius    = 200.0;
        float vDeg      = 20.0;
        float degPerSec = 6.0;
        float startDeg  = 0.0;
        bool cw         = true;
    }

    class FnHelix {
        vec3 center     = vec3(0,0,0);
        float radius    = 200.0;
        float vStartDeg = 15.0;
        float vEndDeg   = 45.0;
        float degPerSec = 6.0;
        float startDeg  = 0.0;
        bool cw         = true;

        vec3 centerEnd = vec3(0,0,0);
        bool hasCenterEnd = false;
        float centerLerpPow = 1.5;
    }

    class FnAscent {
        vec3 center     = vec3(0,0,0);
        float distStart = 800.0;
        float distEnd   = 2400.0;
        float distRate  = 0.0;
        float vDeg      = 89.5;
        float startDeg  = 0.0;
        float degPerSec = 0.0;
        bool  cw        = true;
    }


    class FnPolyline {
        array<vec3> pts;
        bool  closed       = false;
        float speed        = 64.0f;
        float dist         = 200.0f;
        float lookAhead    = 64.0f;
        float heightOffset = 0.0f;
        InterpMode interp  = InterpMode::CatmullRom;

        array<float> cumLen;
        float totalLen = 0.0f;

        FloatCurve heightCurve;
        FloatCurve distCurve;
        FloatCurve lookAheadCurve;

        void RebuildLengths() {
            cumLen.RemoveRange(0, cumLen.Length);
            totalLen = 0.0f;
            if (pts.Length == 0) return;
            cumLen.InsertLast(0.0f);
            for (uint i = 1; i < pts.Length; i++) {
                totalLen += (pts[i] - pts[i - 1]).Length();
                cumLen.InsertLast(totalLen);
            }
            if (closed && pts.Length > 1) {
                totalLen += (pts[0] - pts[pts.Length - 1]).Length();
            }
        }
    }

    class FnOrbitMoving {
        FnPolyline center;
        float radius    = 200.0f;
        float vDeg      = 20.0f;
        float degPerSec = 6.0f;
        float startDeg  = 0.0f;
        bool  cw        = true;

        FloatCurve radiusCurve;
        FloatCurve vDegCurve;
    }

    enum PathMode {
        Keyframes,
        Fn
    }

    class CameraPath {
        string name;
        int version   = 1;
        PathMode mode = PathMode::Keyframes;

        PathMetadata meta;
        array<CamKey> keys;

        string fnName;
        FnCircle fnCircle;
        FnHelix  fnHelix;
        FnPolyline fnPolyline;
        FnOrbitMoving fnMovingOrbit;
        FnAscent fnAscent;

        bool IsValid() const {
            if (mode == PathMode::Keyframes) return keys.Length > 0;
            return meta.duration > 0.0 && fnName.Length > 0;
        }
    }

}
