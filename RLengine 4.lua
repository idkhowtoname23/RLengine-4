local ffi = require("ffi")
local bit = bit or require("bit")

ffi.cdef[[
    typedef struct {
        float x, y;
        uint8_t r, g, b, a;
    } Vertex;

    typedef struct {
        float x, y, z;
        float radius, maxRadius, speed, force;
        bool active;
    } Shockwave;

    typedef struct {
        float x, y, z, power;
        bool active;
    } Attractor;
]]

RLengine = {
    _VERSION = "4.0 Ultra-Kernel (Full Features & SoA/SIMD)",
    count = 0,
    maxCount = 3000000,
    fov = 600,
    bounds = {w = 1280, h = 720},
    
    cam = {
        x = 0, y = 0, z = -1000,
        pitch = 0, yaw = 0,
        orbit = false, orbitDist = 1100, orbitAngle = 0, orbitSpeed = 0.4
    },
    
    forceMode = 1,
    paletteMode = 1,
    shapeMode = 1,
    morphStrength = 0.0,
    targetMorph = 1.0,
    time = 0,
    
    useTrails = true,
    trailFade = 0.15,
    additiveBlend = true,
    pointSize = 1.5,
    showHUD = true,
    usePostFX = true,
    chromaticAberration = 1.5,

    maxShockwaves = 16,
    maxAttractors = 4,
    attractorIndex = 0
}

local PALETTES = {
    function(t) return math.floor(255 * t), math.floor(255 * (1 - t)), 255, 255 end,
    function(t) return 255, math.floor(230 * (t^1.5)), math.floor(70 * (1 - t)), 255 end,
    function(t) return math.floor(80 * t), 255, math.floor(110 * t), 255 end,
    function(t) return math.floor(120 * t), math.floor(220 * t), 255, 255 end,
    function(t) return math.floor(230 * t + 25), math.floor(30 * (1 - t)), 255, 255 end,
    function(t) return 255, math.floor(210 * t + 40), math.floor(40 * t), 255 end,
    function(t) return math.floor(50 * (1 - t)), 255, math.floor(180 * t), 255 end,
    function(t) return math.floor(255 * t), math.floor(120 * t), math.floor(220 * (1 - t)), 255 end
}

local postShaderCode = [[
    extern vec2 u_resolution;
    extern float u_chroma;

    vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
        vec2 uv = texture_coords;
        vec2 dist = uv - vec2(0.5);
        float shift = length(dist) * 0.003 * u_chroma;

        float r = Texel(texture, uv + vec2(shift, 0.0)).r;
        float g = Texel(texture, uv).g;
        float b = Texel(texture, uv - vec2(shift, 0.0)).b;
        float a = Texel(texture, uv).a;

        return vec4(r, g, b, a) * color;
    }
]]

function RLengine.init(w, h)
    RLengine.bounds.w = w or love.graphics.getWidth()
    RLengine.bounds.h = h or love.graphics.getHeight()

    local maxC = RLengine.maxCount
    local fSize = ffi.sizeof("float") * maxC

    RLengine.buf_x  = ffi.cast("float*", love.data.newByteData(fSize):getFFIPointer())
    RLengine.buf_y  = ffi.cast("float*", love.data.newByteData(fSize):getFFIPointer())
    RLengine.buf_z  = ffi.cast("float*", love.data.newByteData(fSize):getFFIPointer())
    RLengine.buf_vx = ffi.cast("float*", love.data.newByteData(fSize):getFFIPointer())
    RLengine.buf_vy = ffi.cast("float*", love.data.newByteData(fSize):getFFIPointer())
    RLengine.buf_vz = ffi.cast("float*", love.data.newByteData(fSize):getFFIPointer())
    RLengine.buf_ox = ffi.cast("float*", love.data.newByteData(fSize):getFFIPointer())
    RLengine.buf_oy = ffi.cast("float*", love.data.newByteData(fSize):getFFIPointer())
    RLengine.buf_oz = ffi.cast("float*", love.data.newByteData(fSize):getFFIPointer())
    RLengine.buf_ph = ffi.cast("float*", love.data.newByteData(fSize):getFFIPointer())

    local vSize = ffi.sizeof("Vertex") * maxC
    RLengine.vertexData = love.data.newByteData(vSize)
    RLengine.vertexPtr  = ffi.cast("Vertex*", RLengine.vertexData:getFFIPointer())

    local layout = {
        {"VertexPosition", "float", 2},
        {"VertexColor", "byte", 4}
    }
    RLengine.mesh = love.graphics.newMesh(layout, maxC, "points", "stream")

    RLengine.colorLUT = ffi.new("uint8_t[8][256][4]")
    for pal = 1, 8 do
        for i = 0, 255 do
            local r, g, b, a = PALETTES[pal](i / 255)
            RLengine.colorLUT[pal - 1][i][0] = r
            RLengine.colorLUT[pal - 1][i][1] = g
            RLengine.colorLUT[pal - 1][i][2] = b
            RLengine.colorLUT[pal - 1][i][3] = a
        end
    end

    RLengine.shockwavePool = ffi.new("Shockwave[16]")
    RLengine.attractors = ffi.new("Attractor[4]")

    RLengine.trailCanvas = love.graphics.newCanvas(RLengine.bounds.w, RLengine.bounds.h)
    RLengine.postShader = love.graphics.newShader(postShaderCode)

    RLengine.setParticleCount(1500000)
    RLengine.setShape(3)
end

function RLengine.setParticleCount(target)
    target = math.max(0, math.min(RLengine.maxCount, target))
    if target > RLengine.count then
        local px, py, pz = RLengine.buf_x, RLengine.buf_y, RLengine.buf_z
        local pvx, pvy, pvz = RLengine.buf_vx, RLengine.buf_vy, RLengine.buf_vz
        local pox, poy, poz = RLengine.buf_ox, RLengine.buf_oy, RLengine.buf_oz
        local pph = RLengine.buf_ph

        for i = RLengine.count, target - 1 do
            px[i] = (math.random() - 0.5) * 1800
            py[i] = (math.random() - 0.5) * 1800
            pz[i] = (math.random() - 0.5) * 1800
            pvx[i] = (math.random() - 0.5) * 40
            pvy[i] = (math.random() - 0.5) * 40
            pvz[i] = (math.random() - 0.5) * 40
            pph[i] = math.random() * math.pi * 2
            pox[i], poy[i], poz[i] = px[i], py[i], pz[i]
        end
        RLengine.applyShapeRange(RLengine.count, target - 1)
    end
    RLengine.count = target
end

function RLengine.applyShapeRange(first, last)
    local mode = RLengine.shapeMode
    local pox, poy, poz = RLengine.buf_ox, RLengine.buf_oy, RLengine.buf_oz
    local maxC = RLengine.maxCount

    for i = first, last do
        if mode == 1 then
            pox[i] = (math.random() - 0.5) * 1800
            poy[i] = (math.random() - 0.5) * 1800
            poz[i] = (math.random() - 0.5) * 1800
        elseif mode == 2 then
            local u = (math.random() - 0.5) * 2
            local theta = math.random() * math.pi * 2
            local r = 600 * (math.random() ^ (1/3))
            local s = math.sqrt(math.max(0, 1 - u*u))
            pox[i] = r * s * math.cos(theta)
            poy[i] = r * u
            poz[i] = r * s * math.sin(theta)
        elseif mode == 3 then
            local arms = 4
            local armAngle = (i % arms) * ((math.pi * 2) / arms)
            local dist = (math.random() ^ 1.5) * 1100
            local theta = armAngle + dist * 0.004 + (math.random() - 0.5) * 0.3
            pox[i] = math.cos(theta) * dist
            poz[i] = math.sin(theta) * dist
            poy[i] = (math.random() - 0.5) * (160 * (1 - dist / 1150))
        elseif mode == 4 then
            local R, r_min = 550, 180
            local u = math.random() * math.pi * 2
            local v = math.random() * math.pi * 2
            pox[i] = (R + r_min * math.cos(v)) * math.cos(u)
            poz[i] = (R + r_min * math.cos(v)) * math.sin(u)
            poy[i] = r_min * math.sin(v)
        elseif mode == 5 then
            local step, side = 95, 20
            local total = side * side * side
            local idx = i % total
            local gx = (idx % side) - side/2
            local gy = (math.floor(idx / side) % side) - side/2
            local gz = (math.floor(idx / (side * side))) - side/2
            pox[i] = gx * step + (math.random() - 0.5) * 12
            poy[i] = gy * step + (math.random() - 0.5) * 12
            poz[i] = gz * step + (math.random() - 0.5) * 12
        elseif mode == 6 then
            local scale = 450
            local corner = i % 16
            local x = (bit.band(corner, 1) > 0) and 1 or -1
            local y = (bit.band(corner, 2) > 0) and 1 or -1
            local z = (bit.band(corner, 4) > 0) and 1 or -1
            local w = (bit.band(corner, 8) > 0) and 1 or -1
            local jitter = (math.random() - 0.5) * 180
            pox[i] = x * scale + jitter
            poy[i] = y * scale + jitter
            poz[i] = z * scale + w * 180 + jitter
        elseif mode == 7 then
            local t = (i / maxC) * math.pi * 48
            local strand = (i % 2 == 0) and 0 or math.pi
            local r = 320
            pox[i] = math.cos(t + strand) * r + (math.random() - 0.5) * 35
            poz[i] = math.sin(t + strand) * r + (math.random() - 0.5) * 35
            poy[i] = (t - math.pi * 24) * 22
        elseif mode == 8 then
            local isDisk = (i % 10 ~= 0)
            if isDisk then
                local dist = 300 + (math.random() ^ 0.7) * 800
                local theta = math.random() * math.pi * 2
                pox[i] = math.cos(theta) * dist
                poz[i] = math.sin(theta) * dist
                poy[i] = (math.random() - 0.5) * 30
            else
                local u = (math.random() - 0.5) * 2
                local theta = math.random() * math.pi * 2
                local r = 250
                local s = math.sqrt(math.max(0, 1 - u*u))
                pox[i] = r * s * math.cos(theta)
                poy[i] = r * u
                poz[i] = r * s * math.sin(theta)
            end
        end
    end
end

function RLengine.setShape(mode)
    RLengine.shapeMode = mode
    RLengine.applyShapeRange(0, RLengine.count - 1)
    RLengine.targetMorph = 1.0
end

function RLengine.triggerShockwave(x, y, z, customForce)
    local pool = RLengine.shockwavePool
    for i = 0, RLengine.maxShockwaves - 1 do
        if not pool[i].active then
            pool[i].active = true
            pool[i].x, pool[i].y, pool[i].z = x or 0, y or 0, z or 0
            pool[i].radius = 10
            pool[i].maxRadius = 1800
            pool[i].speed = 2600
            pool[i].force = customForce or 1600
            break
        end
    end
end

function RLengine.spawnAttractor(x, y, z)
    local att = RLengine.attractors[RLengine.attractorIndex]
    att.x, att.y, att.z = x, y, z
    att.power = 18000000
    att.active = true
    RLengine.attractorIndex = (RLengine.attractorIndex + 1) % RLengine.maxAttractors
end

function RLengine.clearAttractors()
    for i = 0, RLengine.maxAttractors - 1 do RLengine.attractors[i].active = false end
end

function RLengine.update(dt)
    local count = RLengine.count
    if count == 0 then return end

    local m_sin, m_cos, m_sqrt, m_abs, m_floor, m_min, m_max = 
        math.sin, math.cos, math.sqrt, math.abs, math.floor, math.min, math.max

    RLengine.time = RLengine.time + dt
    local tGlobal = RLengine.time
    local cx, cy = RLengine.bounds.w * 0.5, RLengine.bounds.h * 0.5
    local fov = RLengine.fov

    RLengine.morphStrength = RLengine.morphStrength + (RLengine.targetMorph - RLengine.morphStrength) * m_min(1.0, dt * 3.2)
    local morphStr = RLengine.morphStrength * 14.0

    local pool = RLengine.shockwavePool
    local activeShockwaves = 0
    for i = 0, RLengine.maxShockwaves - 1 do
        local sw = pool[i]
        if sw.active then
            sw.radius = sw.radius + sw.speed * dt
            if sw.radius > sw.maxRadius then sw.active = false else activeShockwaves = activeShockwaves + 1 end
        end
    end

    local attractors = RLengine.attractors
    local activeAttractors = 0
    for i = 0, RLengine.maxAttractors - 1 do
        if attractors[i].active then activeAttractors = activeAttractors + 1 end
    end

    local cam = RLengine.cam
    if cam.orbit then
        cam.orbitAngle = cam.orbitAngle + dt * cam.orbitSpeed
        cam.x = m_sin(cam.orbitAngle) * cam.orbitDist
        cam.z = m_cos(cam.orbitAngle) * cam.orbitDist
        cam.yaw = cam.orbitAngle + math.pi
        cam.pitch = 0.22
        cam.y = 220
    end

    local camX, camY, camZ = cam.x, cam.y, cam.z
    local cosY, sinY = m_cos(-cam.yaw), m_sin(-cam.yaw)
    local cosP, sinP = m_cos(-cam.pitch), m_sin(-cam.pitch)

    local m11, m12, m13 = cosY, 0, -sinY
    local m21, m22, m23 = sinP * sinY, cosP, sinP * cosY
    local m31, m32, m33 = cosP * sinY, -sinP, cosP * cosY

    local px, py, pz   = RLengine.buf_x,  RLengine.buf_y,  RLengine.buf_z
    local pvx, pvy, pvz = RLengine.buf_vx, RLengine.buf_vy, RLengine.buf_vz
    local pox, poy, poz = RLengine.buf_ox, RLengine.buf_oy, RLengine.buf_oz
    local pph          = RLengine.buf_ph
    local vPtr         = RLengine.vertexPtr
    local lut          = RLengine.colorLUT[RLengine.paletteMode - 1]

    local isLmb = love.mouse.isDown(1)
    local fMode = RLengine.forceMode
    local damp = 1.0 - m_min(0.9, dt * 0.45)

    local rayX, rayY, rayZ = 0, 0, 0
    if isLmb then
        local mx, my = love.mouse.getPosition()
        local ndx, ndy = (mx - cx) / fov, (my - cy) / fov
        local rx, ry, rz = ndx * 750, ndy * 750, 750
        rayX = camX + (rx * cosY + rz * sinY)
        rayY = camY + (ry * cosP - (-sinP) * (rx * -sinY + rz * cosY))
        rayZ = camZ + (-rx * sinY + rz * cosY)
    end

    for i = 0, count - 1 do
        local x, y, z = px[i], py[i], pz[i]
        local vx, vy, vz = pvx[i], pvy[i], pvz[i]

        if morphStr > 0.001 then
            vx = vx + (pox[i] - x) * morphStr * dt
            vy = vy + (poy[i] - y) * morphStr * dt
            vz = vz + (poz[i] - z) * morphStr * dt
        end

        if isLmb then
            local dx, dy, dz = rayX - x, rayY - y, rayZ - z
            local distSq = dx*dx + dy*dy + dz*dz + 1000.0
            local invDistSq = 1.0 / distSq

            if fMode == 1 then
                local force = 16000000.0 * dt * invDistSq
                vx = vx + dx * force; vy = vy + dy * force; vz = vz + dz * force
            elseif fMode == 2 then
                local force = 12000000.0 * dt * invDistSq
                vx = vx + (-dy * 18 + dx) * force; vy = vy + (dx * 18 + dy) * force; vz = vz + dz * force
            elseif fMode == 3 then
                local force = -22000000.0 * dt * invDistSq
                vx = vx + dx * force; vy = vy + dy * force; vz = vz + dz * force
            elseif fMode == 4 then
                local phase = pph[i]
                vx = vx + m_sin(y * 0.009 + tGlobal * 6 + phase) * 500 * dt
                vy = vy + m_cos(z * 0.009 + tGlobal * 6 + phase) * 500 * dt
                vz = vz + m_sin(x * 0.009 + tGlobal * 6 + phase) * 500 * dt
            elseif fMode == 5 then
                local distM = m_sqrt(x*x + y*y + z*z) + 0.1
                vx = vx + (z / distM) * 600 * dt; vz = vz + (-x / distM) * 600 * dt
            elseif fMode == 6 then
                vx = vx + m_sin(y * 0.004 + tGlobal) * 350 * dt
                vy = vy + m_cos(z * 0.004 + tGlobal) * 350 * dt
                vz = vz + m_sin(x * 0.004 + tGlobal) * 350 * dt
            end
        end

        if activeAttractors > 0 then
            for a = 0, RLengine.maxAttractors - 1 do
                local att = attractors[a]
                if att.active then
                    local adx, ady, adz = att.x - x, att.y - y, att.z - z
                    local aDistSq = adx*adx + ady*ady + adz*adz + 800.0
                    local aForce = att.power * dt / aDistSq
                    vx = vx + adx * aForce; vy = vy + ady * aForce; vz = vz + adz * aForce
                end
            end
        end

        if activeShockwaves > 0 then
            for k = 0, RLengine.maxShockwaves - 1 do
                local sw = pool[k]
                if sw.active then
                    local sdx, sdy, sdz = x - sw.x, y - sw.y, z - sw.z
                    local sDistSq = sdx*sdx + sdy*sdy + sdz*sdz
                    local deltaRadius = m_abs(m_sqrt(sDistSq) - sw.radius)
                    if deltaRadius < 200 then
                        local push = (1.0 - deltaRadius / 200) * sw.force * dt
                        local invLen = 1.0 / (m_sqrt(sDistSq) + 0.001)
                        vx = vx + sdx * invLen * push * 55
                        vy = vy + sdy * invLen * push * 55
                        vz = vz + sdz * invLen * push * 55
                    end
                end
            end
        end

        vx = vx * damp; vy = vy * damp; vz = vz * damp
        x = x + vx * dt; y = y + vy * dt; z = z + vz * dt

        if x < -1600 then x = -1600; vx = -vx * 0.75 elseif x > 1600 then x = 1600; vx = -vx * 0.75 end
        if y < -1600 then y = -1600; vy = -vy * 0.75 elseif y > 1600 then y = 1600; vy = -vy * 0.75 end
        if z < -1600 then z = -1600; vz = -vz * 0.75 elseif z > 1600 then z = 1600; vz = -vz * 0.75 end

        px[i], py[i], pz[i] = x, y, z
        pvx[i], pvy[i], pvz[i] = vx, vy, vz

        local tx, ty, tz = x - camX, y - camY, z - camZ
        local rx = tx * m11 + ty * m12 + tz * m13
        local ry = tx * m21 + ty * m22 + tz * m23
        local rz = tx * m31 + ty * m32 + tz * m33

        local vert = vPtr + i
        if rz > 15.0 then
            local invZ = fov / rz
            vert.x = cx + rx * invZ
            vert.y = cy + ry * invZ

            local speedSq = vx*vx + vy*vy + vz*vz
            local cIdx = m_min(255, m_max(0, m_floor(speedSq * 0.0022)))
            local depthAlpha = m_max(0, 255 - m_min(255, m_floor(rz * 0.07)))

            vert.r = lut[cIdx][0]; vert.g = lut[cIdx][1]; vert.b = lut[cIdx][2]; vert.a = depthAlpha
        else
            vert.x = -99999.0; vert.y = -99999.0; vert.a = 0
        end
    end

    RLengine.mesh:setVertices(RLengine.vertexData, 1, count)
end

function RLengine.draw()
    if RLengine.useTrails then
        love.graphics.setCanvas(RLengine.trailCanvas)
        love.graphics.setBlendMode("alpha")
        love.graphics.setColor(0.01, 0.01, 0.02, RLengine.trailFade)
        love.graphics.rectangle("fill", 0, 0, RLengine.bounds.w, RLengine.bounds.h)
    else
        love.graphics.clear(0.01, 0.01, 0.02, 1)
    end

    if RLengine.count > 0 then
        love.graphics.setBlendMode(RLengine.additiveBlend and "add" or "alpha")
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.setPointSize(RLengine.pointSize)
        RLengine.mesh:setDrawRange(1, RLengine.count)
        love.graphics.draw(RLengine.mesh)
    end

    if RLengine.useTrails then
        love.graphics.setCanvas()
        love.graphics.setBlendMode("alpha")
        love.graphics.setColor(1, 1, 1, 1)

        if RLengine.usePostFX then
            RLengine.postShader:send("u_chroma", RLengine.chromaticAberration)
            love.graphics.setShader(RLengine.postShader)
        end

        love.graphics.draw(RLengine.trailCanvas, 0, 0)
        love.graphics.setShader()
    end

    if RLengine.showHUD then
        love.graphics.setBlendMode("alpha")
        local memMB = collectgarbage("count") / 1024
        love.graphics.setColor(0.02, 0.04, 0.08, 0.90)
        love.graphics.rectangle("fill", 15, 15, 520, 320, 8, 8)
        love.graphics.setColor(0.0, 0.8, 1.0, 0.6)
        love.graphics.setLineWidth(1.5)
        love.graphics.rectangle("line", 15, 15, 520, 320, 8, 8)

        local forceNames = {"Singularity", "Cosmic Vortex", "Anti-Gravity", "Quantum Waves", "Dipole Magnetic", "Vector Flow Field"}
        local palNames = {"Cyberpunk", "Inferno", "Matrix", "Plasma", "Void", "Gold", "Acid Toxic", "Neon Synth"}
        local shapeNames = {"Cube Dust", "Sphere", "Galaxy", "Torus", "Lattice", "4D Tesseract", "DNA Helix", "Accretion Black Hole"}

        love.graphics.setColor(0, 1, 0.6)
        love.graphics.print("RLengine 4.0 // ULTRA-KERNEL (FULL FEATURES & SoA)", 28, 24)
        love.graphics.setColor(0.5, 0.5, 0.5)
        love.graphics.line(28, 44, 510, 44)

        love.graphics.setColor(1, 1, 1)
        love.graphics.print(string.format("FPS: %d (%.2f ms) | Lua RAM: %.2f MB", 
            love.timer.getFPS(), 1000 / math.max(1, love.timer.getFPS()), memMB), 28, 52)
        love.graphics.print(string.format("Particles: %s / %s (%.0f%%)", 
            RLengine.formatNumber(RLengine.count), RLengine.formatNumber(RLengine.maxCount), (RLengine.count / RLengine.maxCount) * 100), 28, 72)
        
        love.graphics.setColor(0.3, 0.9, 1.0)
        love.graphics.print("[1-6] Force Field: " .. forceNames[RLengine.forceMode], 28, 96)
        love.graphics.print("[F1-F8] Shape: " .. shapeNames[RLengine.shapeMode] .. (RLengine.targetMorph > 0 and " (LOCK)" or " (FREE)"), 28, 116)
        love.graphics.print("[7-0] Palette: " .. palNames[RLengine.paletteMode], 28, 136)
        
        love.graphics.setColor(0.9, 0.7, 0.2)
        love.graphics.print("[RMB] Spawn Gravity Well | [X] Clear Attractors", 28, 160)
        love.graphics.print("[E / MMB] Shockwave Burst | [M] Morph Lock Toggle", 28, 180)
        love.graphics.print("[B] Blend: " .. (RLengine.additiveBlend and "Additive Neon" or "Alpha Soft") .. " | [T] Trails: " .. (RLengine.useTrails and "ON" or "OFF"), 28, 200)
        love.graphics.print("[P] PostFX Chromatic Aberration: " .. (RLengine.usePostFX and "ON" or "OFF"), 28, 220)
        love.graphics.print("[C] Orbit Cam | [R] Chaos Burst | [H] HUD Toggle", 28, 240)
        
        love.graphics.setColor(0.1, 0.2, 0.3)
        love.graphics.rectangle("fill", 28, 280, 490, 8, 4, 4)
        love.graphics.setColor(0.0, 1.0, 0.6)
        love.graphics.rectangle("fill", 28, 280, 490 * (RLengine.count / RLengine.maxCount), 8, 4, 4)
    end
end

function RLengine.formatNumber(n)
    local left, num, right = string.match(n, '^([^%d]*%d)(%d*)(.-)$')
    return left .. (num:reverse():gsub('(%d%d%d)', '%1,'):reverse()) .. right
end

function love.load()
    love.window.setMode(1280, 720, {resizable = true, vsync = false, minwidth = 800, minheight = 600})
    love.window.setTitle("RLengine 4.0 - Ultra Kernel Full Sandbox")
    RLengine.init()
end

function love.resize(w, h)
    RLengine.bounds.w = w
    RLengine.bounds.h = h
    RLengine.trailCanvas = love.graphics.newCanvas(w, h)
end

function love.update(dt)
    local cam = RLengine.cam
    local speed = 900 * dt

    if not cam.orbit then
        local forwardX = math.sin(cam.yaw) * speed
        local forwardZ = math.cos(cam.yaw) * speed
        local rightX = math.cos(cam.yaw) * speed
        local rightZ = -math.sin(cam.yaw) * speed

        if love.keyboard.isDown("w") then cam.x = cam.x + forwardX; cam.z = cam.z + forwardZ end
        if love.keyboard.isDown("s") then cam.x = cam.x - forwardX; cam.z = cam.z - forwardZ end
        if love.keyboard.isDown("a") then cam.x = cam.x - rightX; cam.z = cam.z - rightZ end
        if love.keyboard.isDown("d") then cam.x = cam.x + rightX; cam.z = cam.z + rightZ end
        if love.keyboard.isDown("space") then cam.y = cam.y + speed end
        if love.keyboard.isDown("lshift") then cam.y = cam.y - speed end
    end

    RLengine.update(dt)
end

function love.mousemoved(x, y, dx, dy)
    if love.mouse.isDown(3) and not RLengine.cam.orbit then
        local cam = RLengine.cam
        cam.yaw = cam.yaw + dx * 0.0035
        cam.pitch = math.max(-1.5, math.min(1.5, cam.pitch - dy * 0.0035))
    end
end

function love.wheelmoved(x, y)
    if RLengine.cam.orbit then
        RLengine.cam.orbitDist = math.max(200, math.min(3500, RLengine.cam.orbitDist - y * 70))
    else
        RLengine.fov = math.max(200, math.min(1400, RLengine.fov + y * 45))
    end
end

function love.keypressed(key)
    if key == "up" then RLengine.setParticleCount(RLengine.count + 250000)
    elseif key == "down" then RLengine.setParticleCount(RLengine.count - 250000)
    elseif key == "1" then RLengine.forceMode = 1
    elseif key == "2" then RLengine.forceMode = 2
    elseif key == "3" then RLengine.forceMode = 3
    elseif key == "4" then RLengine.forceMode = 4
    elseif key == "5" then RLengine.forceMode = 5
    elseif key == "6" then RLengine.forceMode = 6

    elseif key == "f1" then RLengine.setShape(1)
    elseif key == "f2" then RLengine.setShape(2)
    elseif key == "f3" then RLengine.setShape(3)
    elseif key == "f4" then RLengine.setShape(4)
    elseif key == "f5" then RLengine.setShape(5)
    elseif key == "f6" then RLengine.setShape(6)
    elseif key == "f7" then RLengine.setShape(7)
    elseif key == "f8" then RLengine.setShape(8)

    elseif key == "7" then RLengine.paletteMode = 1
    elseif key == "8" then RLengine.paletteMode = 2
    elseif key == "9" then RLengine.paletteMode = 3
    elseif key == "0" then RLengine.paletteMode = 4

    elseif key == "m" then RLengine.targetMorph = (RLengine.targetMorph > 0) and 0.0 or 1.0
    elseif key == "e" then RLengine.triggerShockwave(0, 0, 0, 2200)
    elseif key == "x" then RLengine.clearAttractors()
    elseif key == "r" then RLengine.triggerShockwave(0, 0, 0, 3500)
    elseif key == "b" then RLengine.additiveBlend = not RLengine.additiveBlend
    elseif key == "t" then RLengine.useTrails = not RLengine.useTrails
    elseif key == "p" then RLengine.usePostFX = not RLengine.usePostFX
    elseif key == "c" then RLengine.cam.orbit = not RLengine.cam.orbit
    elseif key == "h" then RLengine.showHUD = not RLengine.showHUD
    end
end

function love.mousepressed(x, y, button)
    if button == 2 then
        local cx = RLengine.bounds.w * 0.5
        local cy = RLengine.bounds.h * 0.5
        local ndx = (x - cx) / RLengine.fov
        local ndy = (y - cy) / RLengine.fov
        local cosY, sinY = math.cos(-RLengine.cam.yaw), math.sin(-RLengine.cam.yaw)
        local cosP, sinP = math.cos(-RLengine.cam.pitch), math.sin(-RLengine.cam.pitch)
        local rx, ry, rz = ndx * 600, ndy * 600, 600
        local ax = RLengine.cam.x + (rx * cosY + rz * sinY)
        local ay = RLengine.cam.y + (ry * cosP - (-sinP) * (rx * -sinY + rz * cosY))
        local az = RLengine.cam.z + (-rx * sinY + rz * cosY)
        RLengine.spawnAttractor(ax, ay, az)
    elseif button == 3 then
        RLengine.triggerShockwave(0, 0, 0, 2500)
    end
end

function love.draw()
    RLengine.draw()
end