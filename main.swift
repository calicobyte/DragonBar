// DragonBar — a long serpent dragon that slithers across the Touch Bar and sometimes breathes fire.
// SPDX-License-Identifier: GPL-2.0-only
//
// Touch / drag on the bar: the dragon flies figure-8s around your finger, breathing fire at it.
// 🐔 button: release a chick for the dragon to hunt (30 s cooldown).
// Double-tap: hide it (tap the 🐉 in the Control Strip to bring it back).
// Menu bar 🐉: show / hide / quit (or `pkill DragonBar`).

import Cocoa
import QuartzCore

// MARK: - System-wide Touch Bar (private DFRFoundation API, same technique as Pock / MTMR)

private let dfrHandle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)

private func dfrFunction<T>(_ name: String, as type: T.Type) -> T? {
    guard let h = dfrHandle, let sym = dlsym(h, name) else { return nil }
    return unsafeBitCast(sym, to: type)
}

enum SystemTouchBar {
    static func setControlStripPresence(_ id: NSTouchBarItem.Identifier, _ present: Bool) {
        typealias Fn = @convention(c) (NSString, Bool) -> Void
        dfrFunction("DFRElementSetControlStripPresenceForIdentifier", as: Fn.self)?(id.rawValue as NSString, present)
    }

    static func showsCloseBox(_ show: Bool) {
        typealias Fn = @convention(c) (Bool) -> Void
        dfrFunction("DFRSystemModalShowsCloseBoxWhenFrontMost", as: Fn.self)?(show)
    }

    static func addSystemTrayItem(_ item: NSTouchBarItem) {
        let sel = NSSelectorFromString("addSystemTrayItem:")
        let cls: AnyObject = NSTouchBarItem.self
        if cls.responds(to: sel) { _ = cls.perform(sel, with: item) }
    }

    static func present(_ bar: NSTouchBar, trayID: NSTouchBarItem.Identifier) {
        let cls: AnyClass = NSTouchBar.self
        // placement 1 = full width (Control Strip hidden)
        let withPlacement = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
        if let m = class_getClassMethod(cls, withPlacement) {
            typealias Fn = @convention(c) (AnyClass, Selector, NSTouchBar, Int64, NSString) -> Void
            unsafeBitCast(method_getImplementation(m), to: Fn.self)(cls, withPlacement, bar, 1, trayID.rawValue as NSString)
            return
        }
        for name in ["presentSystemModalTouchBar:systemTrayItemIdentifier:",
                     "presentSystemModalFunctionBar:systemTrayItemIdentifier:"] {
            let sel = NSSelectorFromString(name)
            if let m = class_getClassMethod(cls, sel) {
                typealias Fn = @convention(c) (AnyClass, Selector, NSTouchBar, NSString) -> Void
                unsafeBitCast(method_getImplementation(m), to: Fn.self)(cls, sel, bar, trayID.rawValue as NSString)
                return
            }
        }
    }

    static func minimize(_ bar: NSTouchBar) {
        let cls: AnyClass = NSTouchBar.self
        for name in ["minimizeSystemModalTouchBar:", "minimizeSystemModalFunctionBar:"] {
            let sel = NSSelectorFromString(name)
            if let m = class_getClassMethod(cls, sel) {
                typealias Fn = @convention(c) (AnyClass, Selector, NSTouchBar) -> Void
                unsafeBitCast(method_getImplementation(m), to: Fn.self)(cls, sel, bar)
                return
            }
        }
    }
}

// MARK: - Helpers

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

private func rand(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { CGFloat.random(in: lo...hi) }

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

private extension CGMutablePath {
    func addPolygon(_ pts: [CGPoint]) {
        guard let first = pts.first else { return }
        move(to: first)
        for p in pts.dropFirst() { addLine(to: p) }
        closeSubpath()
    }
}

// MARK: - Dragon view

final class DragonView: NSView {
    private struct Particle {
        var x, y, vx, vy, age, life, size: CGFloat
        var ember: Bool
    }

    private struct Star { var x, y, r, phase, speed: CGFloat }

    /// A burning letter knocked off the clock.
    private struct Shard {
        var text: String
        var fontSize: CGFloat
        var bold: Bool
        var x, y, vx, vy, angle, spin, age, life: CGFloat
    }

    private struct Chick {
        var pos: CGPoint
        var vel: CGPoint
        var target: CGPoint
        var flap: CGFloat = 0
        var retargetIn: CGFloat = 0
        var dodgeCooldown: CGFloat = 0
        var age: CGFloat = 0
        var boost: CGFloat = 0       // seconds of panicked burst speed left
        var fear: CGFloat = 0        // 0 calm ... 1 dragon right on it
        var sweatCarry: CGFloat = 0
        var misses = 0
    }

    private struct Sweat { var x, y, vx, vy, age, life: CGFloat }

    private struct Heart { var x, y, vx, vy, age, life, size, phase: CGFloat }

    private struct Fluff { var x, y, vx, vy, age, life, angle: CGFloat }

    /// A letter flying back into place during the clock's rebirth.
    private struct RebirthGlyph {
        var text: String
        var bold: Bool
        var fontSize: CGFloat
        var center: CGPoint
        var from: CGPoint      // offset it flies in from
        var spin: CGFloat
        var start: CGFloat     // 0...1 within the rebirth
    }

    private struct RebirthSpark {
        var from: CGPoint      // offset from target
        var target: CGPoint
        var swirl: CGFloat
        var delay: CGFloat
        var cool: Bool         // cyan instead of gold
    }

    private enum ClockState {
        case alive
        case destroyed(passesLeft: Int)
        case regenerating(progress: CGFloat)
    }

    /// Body centerline sampled from the head (index 0) to past the tail tip, in view coordinates.
    private struct Spine {
        var points: [CGPoint] = []
        var normals: [CGPoint] = []   // unit, always pointing "up-ish"
        var back: [CGPoint] = []      // unit tangent pointing toward the tail
        var widths: [CGFloat] = []    // half-thickness
        var bodyCount = 0             // samples that belong to the body (the rest extend into the tail tuft)
    }

    var onDoubleTap: (() -> Void)?

    // Palette
    private let bodyMid = rgb(0.07, 0.48, 0.32)
    private let bodyTop = rgb(0.30, 0.82, 0.52)
    private let bodyBottom = rgb(0.04, 0.33, 0.22)
    private let bodyDark = rgb(0.02, 0.22, 0.15)
    private let belly = rgb(0.98, 0.80, 0.38)
    private let bellyLine = rgb(0.76, 0.52, 0.18, 0.85)
    private let fin = rgb(0.92, 0.28, 0.14)
    private let mane = [rgb(1.0, 0.72, 0.22), rgb(0.95, 0.42, 0.12), rgb(1.0, 0.85, 0.40), rgb(0.85, 0.25, 0.10)]
    private let horn = rgb(0.96, 0.92, 0.80)

    // Simulation state
    private var time: CGFloat = 0
    private var head = CGPoint.zero
    private var heading: CGFloat = 0        // radians, direction of travel
    private var headFlip: CGFloat = 1       // 1 = head drawn upright facing right, -1 = mirrored for leftward travel
    private var currentSpeed: CGFloat = 0
    private var direction: CGFloat = 1      // free-flight travel direction
    private var wavePhase: CGFloat = 0
    private var turnLock: CGFloat = 0       // committed turn direction during a U-turn
    private var trail: [CGPoint] = []       // where the head has been, oldest first; the body follows it
    private var fireTimeLeft: CGFloat = 0
    private var nextFireIn: CGFloat = 2.0
    private var jaw: CGFloat = 0
    private var particles: [Particle] = []
    private var emitCarry: CGFloat = 0
    private var stars: [Star] = []

    // Clock the dragon keeps torching
    private var clockState = ClockState.alive
    private var clockDamage: CGFloat = 0     // 0...1, destroyed at 1
    private var clockFlash: CGFloat = 0
    private var immunityLeft: CGFloat = 0    // seconds the reborn clock can't be hurt
    private var shieldFlash: CGFloat = 0
    private var torchThisPass = true         // while immune the dragon only sometimes bothers
    private var rebirthGlyphs: [RebirthGlyph] = []
    private var rebirthSparks: [RebirthSpark] = []
    private let immunityDuration: CGFloat = 240
    private let rebirthDuration: CGFloat = 2.4
    private var shards: [Shard] = []
    private var clockText = (time: "", date: "")
    private var clockTextAt: CFTimeInterval = 0
    private let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
    private let dateFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE MMM d"; return f }()
    var debugLog: ((String) -> Void)?

    // Atmosphere
    private var skyLight = SkyLight(daylight: 0, twilight: 0, sunT: 0, elevation: -1)
    private var skyRefreshIn: CGFloat = 0
    private var skyHourOverride: CGFloat?
    private var weather = Weather.clear
    private var weatherTimer: CGFloat = 0
    private var weatherLocked = false
    private var cloudAmount: CGFloat = 0.28
    private var rainAmount: CGFloat = 0
    private var clouds: [Cloud] = []
    private var drops: [Drop] = []
    private var dropCarry: CGFloat = 0
    private var splashes: [Splash] = []
    private var lightningTimer: CGFloat = 8
    private var bolt: [CGPoint] = []
    private var boltAge: CGFloat = 10
    private var shootingStars: [ShootingStar] = []
    private var shootingTimer: CGFloat = 5

    // Feeding
    private var chick: Chick?
    private var feedCooldown: CGFloat = 0
    private let feedCooldownDuration: CGFloat = 30
    private var feedReadyPulse: CGFloat = 0
    private var buttonPress: CGFloat = 0
    private var buttonTouch = false
    private var thanking = false
    private var thankU: CGFloat = 0
    private var thankEndU: CGFloat = 0
    private var hearts: [Heart] = []
    private var heartCarry: CGFloat = 0
    private var fluff: [Fluff] = []
    private var sweat: [Sweat] = []
    private var chompCooldown: CGFloat = 0   // after a missed snap the jaw stays shut briefly
    private var hungryJaw = false

    // Finger chasing
    private var chaseX: CGFloat?
    private var fingerDown = false
    private var chaseUntil: CGFloat = 0     // keep chasing briefly after the finger lifts
    private var heat: CGFloat = 0           // how much fire is landing on the finger
    private var chaseU: CGFloat = 0         // distance along the figure-8 of the point the dragon is pursuing
    private var eagerFire = false           // first pass at a new touch always gets a blast
    private var chasingLastStep = false

    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var lastTap: CFTimeInterval = 0

    private let speed: CGFloat = 85        // points / second
    private let designHeight: CGFloat = 30
    private let bodyLength: CGFloat = 260  // design units
    private let tuftLength: CGFloat = 12
    private let samples = 96

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        allowedTouchTypes = [.direct]
        translatesAutoresizingMaskIntoConstraints = false
        let preferred = widthAnchor.constraint(equalToConstant: 1085)
        preferred.priority = .defaultLow
        preferred.isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stars = (0..<70).map { _ in
            Star(x: rand(0, 1), y: rand(0.08, 0.95), r: rand(0.25, 0.75),
                 phase: rand(0, .pi * 2), speed: rand(0.8, 2.6))
        }
        makeClouds()
        // Start clear; the weather wanders from there.
        weather = .clear
        weatherTimer = rand(180, 420)
        refreshSkyLight()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Animation loop

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastTick, 0.1))
        lastTick = now
        step(dt)
        needsDisplay = true
    }

    private var scale: CGFloat { max(bounds.height, 1) / designHeight }
    private var midY: CGFloat { bounds.height * 0.5 + 0.5 * scale }

    private var isOnScreen: Bool { head.x > 30 && head.x < bounds.width - 30 }

    private var isChasing: Bool { chaseX != nil && (fingerDown || time < chaseUntil) }

    func breatheFire(duration: CGFloat = rand(0.9, 1.7)) {
        fireTimeLeft = max(fireTimeLeft, duration)
    }

    private func resetTrail() {
        let s = scale
        head = CGPoint(x: -20 * s, y: midY)
        heading = 0
        headFlip = 1
        direction = 1
        currentSpeed = speed * s
        let length = (bodyLength + tuftLength + 30) * s
        trail = stride(from: head.x - length, through: head.x, by: 2 * s).map { CGPoint(x: $0, y: midY) }
    }

    private func pruneTrail() {
        let keep = (bodyLength + tuftLength + 30) * scale
        var total: CGFloat = 0
        var i = trail.count - 1
        while i > 0 && total < keep {
            total += hypot(trail[i].x - trail[i - 1].x, trail[i].y - trail[i - 1].y)
            i -= 1
        }
        if i > 0 { trail.removeFirst(i) }
    }

    func step(_ dt: CGFloat) {
        guard bounds.height > 0 else { return }
        if trail.isEmpty { resetTrail() }
        let s = scale
        let mid = midY
        time += dt

        let wasChasing = chasingLastStep
        chasingLastStep = isChasing
        if chaseX != nil && !isChasing {
            chaseX = nil
            direction = cos(heading) >= 0 ? 1 : -1
        }

        var desiredHeading: CGFloat
        var desiredSpeed: CGFloat
        if isChasing, let fx = chaseX {
            // Fly figure-8 laps centered on the finger, swooping through it each way.
            if !wasChasing { chaseU = figureEightEntry(fx) }
            (desiredHeading, desiredSpeed) = pursueFigureEight(fx, &chaseU)

            // Breathe fire in random bursts while heading at the finger.
            let toFinger = fx - head.x
            let aimed = toFinger * cos(heading) > 0 && abs(toFinger) < 120 * s && abs(cos(heading)) > 0.75
            if aimed {
                if fireTimeLeft <= 0 && (eagerFire || CGFloat.random(in: 0...1) < dt * 1.6) {
                    fireTimeLeft = rand(0.35, 0.9)
                    eagerFire = false
                }
            } else {
                fireTimeLeft = 0
            }
        } else if let c = chick {
            // Hunt the chick, leading it a little.
            let aim = CGPoint(x: c.pos.x + c.vel.x * 0.2, y: c.pos.y + c.vel.y * 0.2)
            desiredHeading = atan2(aim.y - head.y, aim.x - head.x)
            desiredSpeed = 150 * s
            fireTimeLeft = 0
            let d = hypot(c.pos.x - head.x, c.pos.y - head.y)
            hungryJaw = chompCooldown <= 0 && d < 40 * s
                && ((c.pos.x - head.x) * cos(heading) + (c.pos.y - head.y) * sin(heading)) > 0
        } else if thanking {
            // Thank-you figure-8 right where it ate, trailing hearts.
            (desiredHeading, desiredSpeed) = pursueFigureEight(thankX, &thankU)
            fireTimeLeft = 0
            heartCarry += dt * 7
            while heartCarry >= 1 { heartCarry -= 1; spawnHeart() }
            if thankU >= thankEndU {
                thanking = false
                direction = cos(heading) >= 0 ? 1 : -1
            }
        } else {
            // Free flight: slither across, loop around once well past the edge.
            if direction > 0 && head.x > bounds.width + 110 * s { direction = -1; passCompleted() }
            else if direction < 0 && head.x < -110 * s { direction = 1; passCompleted() }
            wavePhase += currentSpeed * dt * 0.045 / s
            let target = CGPoint(x: head.x + direction * 30 * s,
                                 y: mid + s * (6 * sin(wavePhase + 0.9) + 1.5 * sin(2.3 * wavePhase + 1)))
            desiredHeading = atan2(target.y - head.y, target.x - head.x)
            desiredSpeed = speed * s * (fireTimeLeft > 0 ? 0.4 : 1)

            // Torch the clock on the way past it.
            let clock = clockLayout().rect
            if case .alive = clockState, torchThisPass, direction < 0, cos(heading) < -0.7,
               head.x > clock.minX, head.x - clock.maxX < 100 * s {
                fireTimeLeft = max(fireTimeLeft, 0.2)
            }

            if fireTimeLeft <= 0 {
                nextFireIn -= dt
                if nextFireIn <= 0 {
                    if isOnScreen { breatheFire() }
                    nextFireIn = rand(2.5, 6.5)
                }
            }
        }
        if fireTimeLeft > 0 { fireTimeLeft -= dt }

        // Steering. A reversal commits to one turn direction (toward the vertical middle) so it loops cleanly.
        var delta = remainder(desiredHeading - heading, 2 * .pi)
        if turnLock != 0 {
            if abs(delta) < 1.0 { turnLock = 0 } else { delta = abs(delta) * turnLock }
        } else if abs(delta) > 2.4 {
            let wantUp = head.y < mid
            turnLock = (wantUp == (cos(heading) >= 0)) ? 1 : -1
            delta = abs(delta) * turnLock
        }
        let maxTurn = 10 * dt
        heading += max(-maxTurn, min(maxTurn, delta))
        if abs(delta) > 1 { desiredSpeed = min(desiredSpeed, 85 * s) }  // loops just fit in 30pt

        currentSpeed += (desiredSpeed - currentSpeed) * min(1, dt * 4)
        head.x += cos(heading) * currentSpeed * dt
        head.y += sin(heading) * currentSpeed * dt
        head.y = min(max(head.y, 4 * s), bounds.height - 4 * s)
        if abs(cos(heading)) > 0.25 { headFlip = cos(heading) >= 0 ? 1 : -1 }

        if let last = trail.last, hypot(head.x - last.x, head.y - last.y) >= 1.2 * s {
            trail.append(head)
            pruneTrail()
        }

        if chick == nil { hungryJaw = false }
        let jawTarget: CGFloat = (fireTimeLeft > 0 || hungryJaw) ? 1 : 0
        jaw += (jawTarget - jaw) * min(1, dt * 14)

        // Emit fire from the mouth.
        if fireTimeLeft > 0 && jaw > 0.55 {
            let t = headTransform()
            let mouth = CGPoint(x: 11, y: -2.4).applying(t)
            let fwd = CGPoint(x: 1, y: 0).applying(CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: 0, ty: 0))
            let baseAngle = atan2(fwd.y, fwd.x)
            emitCarry += dt * 260
            while emitCarry >= 1 {
                emitCarry -= 1
                let ember = CGFloat.random(in: 0...1) < 0.08
                let a = baseAngle + rand(-0.15, 0.15)
                let v = rand(150, 240) * s
                let lead = rand(-1, 2) * s
                particles.append(Particle(
                    x: mouth.x + cos(a) * lead,
                    y: mouth.y + sin(a) * lead,
                    vx: cos(a) * v + cos(heading) * currentSpeed * 0.4,
                    vy: sin(a) * v + rand(-8, 8) * s,
                    age: 0,
                    life: ember ? rand(1.0, 1.8) : rand(0.35, 0.7),
                    size: ember ? rand(0.5, 0.9) * s : rand(1.2, 2.0) * s,
                    ember: ember))
            }
        }

        // Fire landing on the finger heats it up and throws sparks.
        if let fx = chaseX {
            let hits = particles.reduce(0) { $0 + ((!$1.ember && abs($1.x - fx) < 8 * s && abs($1.y - mid) < 12 * s) ? 1 : 0) }
            heat = max(0, min(1, heat + (hits > 3 ? dt * 3 : -dt * 1.5)))
            if heat > 0.4 && CGFloat.random(in: 0...1) < dt * 40 * heat {
                let a = rand(0.3, .pi - 0.3)
                let v = rand(30, 90) * s
                particles.append(Particle(x: fx + rand(-3, 3) * s, y: mid + rand(-3, 3) * s,
                                          vx: cos(a) * v, vy: sin(a) * v, age: 0, life: rand(0.5, 1.0),
                                          size: rand(0.4, 0.8) * s, ember: true))
            }
        } else {
            heat = max(0, heat - dt * 2)
        }

        let drag = pow(0.06, dt)
        particles = particles.compactMap { p in
            var p = p
            p.age += dt
            guard p.age < p.life else { return nil }
            p.vx *= p.ember ? pow(0.4, dt) : drag
            p.vy *= p.ember ? pow(0.4, dt) : drag
            p.vy += (p.ember ? -14 : 22) * s * dt   // flames rise, embers drift down
            p.x += p.vx * dt
            p.y += p.vy * dt
            return p
        }

        updateClock(dt)
        updateFeeding(dt)
        updateAtmosphere(dt)
    }

    // MARK: Clock

    private struct ClockLayout {
        var time: String, date: String
        var timeFont: NSFont, dateFont: NSFont
        var timeOrigin: CGPoint, dateOrigin: CGPoint
        var rect: CGRect
    }

    private func clockLayout() -> ClockLayout {
        let s = scale
        let now = CACurrentMediaTime()
        if clockText.time.isEmpty || now - clockTextAt > 1 {
            let date = Date()
            clockText = (timeFormatter.string(from: date), dateFormatter.string(from: date))
            clockTextAt = now
        }
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 13 * s, weight: .semibold)
        let dateFont = NSFont.systemFont(ofSize: 8.5 * s, weight: .medium)
        let tw = (clockText.time as NSString).size(withAttributes: [.font: timeFont]).width
        let dw = (clockText.date as NSString).size(withAttributes: [.font: dateFont]).width
        let x = 12 * s
        return ClockLayout(time: clockText.time, date: clockText.date, timeFont: timeFont, dateFont: dateFont,
                           timeOrigin: CGPoint(x: x, y: 11.5 * s), dateOrigin: CGPoint(x: x + 0.5 * s, y: 2 * s),
                           rect: CGRect(x: x, y: 2 * s, width: max(tw, dw), height: 26 * s))
    }

    private func passCompleted() {
        torchThisPass = immunityLeft <= 0 || Bool.random()
        if case .destroyed(let left) = clockState {
            if left <= 1 { beginRebirth() } else { clockState = .destroyed(passesLeft: left - 1) }
        }
    }

    private func updateClock(_ dt: CGFloat) {
        let s = scale
        clockFlash = max(0, clockFlash - dt * 2.5)
        shieldFlash = max(0, shieldFlash - dt * 1.6)

        switch clockState {
        case .alive:
            let layout = clockLayout()
            let zone = layout.rect.insetBy(dx: -2 * s, dy: -2 * s)
            immunityLeft = max(0, immunityLeft - dt)
            var hits = 0
            if immunityLeft > 0 {
                // Shield: flames splash off.
                let shield = zone.insetBy(dx: -4 * s, dy: -1 * s)
                for i in particles.indices where !particles[i].ember {
                    let p = particles[i]
                    if shield.contains(CGPoint(x: p.x, y: p.y)) && p.vx * (p.x - shield.midX) < 0 {
                        particles[i].vx = -p.vx * 0.35
                        particles[i].vy = abs(p.vx) * rand(-0.5, 0.5) + 20 * s
                        hits += 1
                    }
                }
                shieldFlash = min(1, shieldFlash + CGFloat(hits) * 0.04)
                hits = 0
            } else {
                hits = particles.reduce(0) { $0 + ((!$1.ember && zone.contains(CGPoint(x: $1.x, y: $1.y))) ? 1 : 0) }
            }
            clockDamage = min(1, clockDamage + CGFloat(hits) * dt * 0.025)
            // Smouldering text sheds embers.
            if clockDamage > 0.15 && CGFloat.random(in: 0...1) < dt * 25 * clockDamage {
                particles.append(Particle(x: rand(layout.rect.minX, layout.rect.maxX), y: rand(layout.rect.minY, layout.rect.maxY),
                                          vx: rand(-10, 10) * s, vy: rand(10, 35) * s, age: 0, life: rand(0.5, 1.1),
                                          size: rand(0.4, 0.8) * s, ember: true))
            }
            if clockDamage >= 1 { destroyClock(layout) }
        case .regenerating(let progress):
            let p = progress + dt / rebirthDuration
            if p >= 1 {
                clockState = .alive
                clockDamage = 0
                immunityLeft = immunityDuration
                shieldFlash = 1
                torchThisPass = Bool.random()
            } else {
                clockState = .regenerating(progress: p)
            }
        case .destroyed:
            break
        }

        shards = shards.compactMap { sh in
            var sh = sh
            sh.age += dt
            guard sh.age < sh.life else { return nil }
            sh.vy -= 70 * s * dt
            sh.vx *= pow(0.6, dt)
            sh.x += sh.vx * dt
            sh.y += sh.vy * dt
            sh.angle += sh.spin * dt
            return sh
        }
    }

    private func beginRebirth() {
        let s = scale
        let layout = clockLayout()
        rebirthGlyphs = []
        rebirthSparks = []
        func add(_ text: String, font: NSFont, origin: CGPoint, bold: Bool) {
            var x = origin.x
            let h = (text as NSString).size(withAttributes: [.font: font]).height
            for ch in text {
                let str = String(ch)
                let w = (str as NSString).size(withAttributes: [.font: font]).width
                if ch != " " {
                    let center = CGPoint(x: x + w / 2, y: origin.y + h / 2)
                    let a = rand(0, 2 * .pi)
                    rebirthGlyphs.append(RebirthGlyph(text: str, bold: bold, fontSize: font.pointSize / s, center: center,
                                                      from: CGPoint(x: cos(a) * rand(20, 45) * s, y: sin(a) * rand(8, 20) * s),
                                                      spin: rand(-4, 4), start: 0))
                    for _ in 0..<4 {
                        let b = rand(0, 2 * .pi), r = rand(25, 70) * s
                        rebirthSparks.append(RebirthSpark(from: CGPoint(x: cos(b) * r, y: sin(b) * r * 0.5), target: center,
                                                          swirl: rand(1.5, 3.5) * (Bool.random() ? 1 : -1),
                                                          delay: rand(0, 0.22), cool: Bool.random()))
                    }
                }
                x += w
            }
        }
        add(layout.time, font: layout.timeFont, origin: layout.timeOrigin, bold: true)
        add(layout.date, font: layout.dateFont, origin: layout.dateOrigin, bold: false)
        // Letters land left to right.
        let minX = rebirthGlyphs.map(\.center.x).min() ?? 0, maxX = rebirthGlyphs.map(\.center.x).max() ?? 1
        for i in rebirthGlyphs.indices {
            rebirthGlyphs[i].start = 0.2 + 0.25 * (rebirthGlyphs[i].center.x - minX) / max(maxX - minX, 1)
        }
        clockState = .regenerating(progress: 0)
        debugLog?("regenerating at \(time)")
    }

    private func destroyClock(_ layout: ClockLayout) {
        let s = scale
        func shatter(_ text: String, font: NSFont, origin: CGPoint, bold: Bool) {
            var x = origin.x
            let h = (text as NSString).size(withAttributes: [.font: font]).height
            for ch in text {
                let str = String(ch)
                let w = (str as NSString).size(withAttributes: [.font: font]).width
                if ch != " " {
                    shards.append(Shard(text: str, fontSize: font.pointSize / s, bold: bold,
                                        x: x + w / 2, y: origin.y + h / 2,
                                        vx: (direction * rand(15, 70) + rand(-20, 20)) * s,
                                        vy: rand(15, 55) * s,
                                        angle: 0, spin: rand(-6, 6), age: 0, life: rand(1.0, 1.7)))
                }
                x += w
            }
        }
        shatter(layout.time, font: layout.timeFont, origin: layout.timeOrigin, bold: true)
        shatter(layout.date, font: layout.dateFont, origin: layout.dateOrigin, bold: false)
        for _ in 0..<70 {
            let a = rand(0, 2 * .pi), v = rand(20, 90) * s
            particles.append(Particle(x: rand(layout.rect.minX, layout.rect.maxX), y: rand(layout.rect.minY, layout.rect.maxY),
                                      vx: cos(a) * v, vy: sin(a) * v, age: 0, life: rand(0.6, 1.4),
                                      size: rand(0.4, 0.9) * s, ember: true))
        }
        clockFlash = 1
        clockState = .destroyed(passesLeft: Int.random(in: 2...4))
        debugLog?("destroyed at \(time)")
    }

    private func drawShield(_ ctx: CGContext, _ layout: ClockLayout) {
        guard immunityLeft > 0 else { return }
        let s = scale
        let rect = layout.rect.insetBy(dx: -6 * s, dy: -0.5 * s)
        let shape = CGPath(roundedRect: rect, cornerWidth: 8 * s, cornerHeight: 8 * s, transform: nil)
        // Barely there at rest, flickers in the last 10 seconds, flares when hit.
        var idle = 0.07 + 0.04 * sin(time * 2)
        if immunityLeft < 10 { idle *= (sin(time * 25) > 0 ? 1.8 : 0.2) }
        let a = min(1, idle + shieldFlash)
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        ctx.addPath(shape)
        ctx.setFillColor(rgb(0.3, 0.7, 1, 0.12 * a))
        ctx.fillPath()
        ctx.addPath(shape)
        ctx.setStrokeColor(rgb(0.5, 0.85, 1, 0.8 * a))
        ctx.setLineWidth(0.8 * s)
        ctx.strokePath()
        if shieldFlash > 0.05 {
            // Hex shimmer while flaring
            ctx.addPath(shape)
            ctx.clip()
            ctx.setStrokeColor(rgb(0.6, 0.9, 1, 0.35 * shieldFlash))
            ctx.setLineWidth(0.4 * s)
            let hex = 4 * s
            var row = 0
            for y in stride(from: rect.minY, through: rect.maxY, by: hex * 0.87) {
                let offset = row % 2 == 0 ? 0 : hex * 0.75
                for x in stride(from: rect.minX - hex + offset, through: rect.maxX, by: hex * 1.5) {
                    ctx.addEllipse(in: CGRect(x: x, y: y, width: hex, height: hex * 0.87))
                }
                row += 1
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawRebirth(_ ctx: CGContext, _ p: CGFloat, _ layout: ClockLayout) {
        let s = scale
        func clamp01(_ v: CGFloat) -> CGFloat { max(0, min(1, v)) }

        // 1. Sparks spiral in to where each letter will land.
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        for sp in rebirthSparks {
            for trail in 0..<4 {
                let u = clamp01((p - sp.delay - CGFloat(trail) * 0.015) / 0.3)
                guard u > 0 && u < 1 else { continue }
                let e = u * u
                let ang = sp.swirl * (1 - u)
                let rx = sp.from.x * cos(ang) - sp.from.y * sin(ang)
                let ry = sp.from.x * sin(ang) + sp.from.y * cos(ang)
                let pos = CGPoint(x: sp.target.x + rx * (1 - e), y: sp.target.y + ry * (1 - e))
                let a = sin(u * .pi) * (1 - CGFloat(trail) * 0.22)
                let r = (0.9 - CGFloat(trail) * 0.15) * s
                ctx.setFillColor(sp.cool ? rgb(0.5, 0.9, 1, a) : rgb(1, 0.8, 0.3, a))
                ctx.fillEllipse(in: CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2))
            }
        }
        ctx.restoreGState()

        // 2. Letters fly in, spinning and shrinking into place, glowing gold.
        let cool = clamp01((p - 0.8) / 0.2)
        for g in rebirthGlyphs {
            let u = clamp01((p - g.start) / 0.3)
            guard u > 0 else { continue }
            let c1: CGFloat = 1.70158, c3 = c1 + 1
            let e = 1 + c3 * pow(u - 1, 3) + c1 * pow(u - 1, 2)   // ease-out-back: overshoots a touch
            let font = g.bold ? NSFont.monospacedDigitSystemFont(ofSize: g.fontSize * s, weight: .semibold)
                              : NSFont.systemFont(ofSize: g.fontSize * s, weight: .medium)
            let base: (CGFloat, CGFloat, CGFloat) = g.bold ? (0.95, 0.95, 0.97) : (0.62, 0.72, 0.88)
            let color = NSColor(srgbRed: lerp(1, base.0, cool), green: lerp(0.82, base.1, cool),
                                blue: lerp(0.35, base.2, cool), alpha: min(1, u * 3))
            let str = g.text as NSString
            let size = str.size(withAttributes: [.font: font])
            ctx.saveGState()
            ctx.translateBy(x: g.center.x + g.from.x * (1 - e), y: g.center.y + g.from.y * (1 - e))
            ctx.rotate(by: g.spin * (1 - e))
            let sc = lerp(2.4, 1, e)
            ctx.scaleBy(x: sc, y: sc)
            ctx.setShadow(offset: .zero, blur: 5 * s * (1 - cool * 0.8), color: rgb(1, 0.7, 0.2, 0.9 * (1 - cool * 0.7)))
            str.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: [.font: font, .foregroundColor: color])
            ctx.restoreGState()
        }

        // 3. Flash and shockwave as it locks in.
        if p > 0.76 {
            let u = clamp01((p - 0.76) / 0.24)
            let c = CGPoint(x: layout.rect.midX, y: layout.rect.midY)
            ctx.saveGState()
            ctx.setBlendMode(.plusLighter)
            let colors = [rgb(1, 0.95, 0.8, 0.7 * (1 - u)), rgb(1, 0.7, 0.3, 0)] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 40 * s, options: [])
            }
            let r = lerp(6, 75, 1 - pow(1 - u, 3)) * s
            ctx.setStrokeColor(rgb(0.6, 0.9, 1, 0.9 * (1 - u)))
            ctx.setLineWidth(lerp(2.5, 0.4, u) * s)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r * 0.45, width: r * 2, height: r * 0.9))
            ctx.restoreGState()
        }
    }

    private func drawClock(_ ctx: CGContext) {
        let s = scale
        let layout = clockLayout()

        if clockFlash > 0.01 {
            let c = CGPoint(x: layout.rect.midX, y: layout.rect.midY)
            let colors = [rgb(1, 0.7, 0.3, 0.8 * clockFlash), rgb(1, 0.3, 0, 0)] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                ctx.saveGState()
                ctx.setBlendMode(.plusLighter)
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 45 * s, options: [])
                ctx.restoreGState()
            }
        }

        var alpha: CGFloat = 1
        var heatLevel: CGFloat = 0
        switch clockState {
        case .alive: heatLevel = clockDamage
        case .regenerating(let p): alpha = 0; drawRebirth(ctx, p, layout)
        case .destroyed: alpha = 0
        }

        if alpha > 0 {
            func heated(_ base: (CGFloat, CGFloat, CGFloat)) -> NSColor {
                let h = heatLevel
                let (r, g, b): (CGFloat, CGFloat, CGFloat) = h < 0.5
                    ? (lerp(base.0, 1, h * 2), lerp(base.1, 0.6, h * 2), lerp(base.2, 0.15, h * 2))
                    : (lerp(1, 0.95, (h - 0.5) * 2), lerp(0.6, 0.22, (h - 0.5) * 2), lerp(0.15, 0.05, (h - 0.5) * 2))
                return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
            }
            ctx.saveGState()
            if heatLevel > 0 {
                ctx.setShadow(offset: .zero, blur: 5 * s, color: rgb(1, 0.45, 0.05, heatLevel))
            } else {
                ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * s), blur: 2.5 * s, color: rgb(0, 0.05, 0.15, 0.25 + 0.45 * skyLight.daylight))
            }
            let jitter = heatLevel > 0.3 ? CGPoint(x: rand(-1, 1) * heatLevel * 0.7 * s, y: rand(-1, 1) * heatLevel * 0.7 * s) : .zero
            (layout.time as NSString).draw(at: CGPoint(x: layout.timeOrigin.x + jitter.x, y: layout.timeOrigin.y + jitter.y),
                                           withAttributes: [.font: layout.timeFont, .foregroundColor: heated((0.95, 0.95, 0.97))])
            (layout.date as NSString).draw(at: CGPoint(x: layout.dateOrigin.x + jitter.x, y: layout.dateOrigin.y + jitter.y),
                                           withAttributes: [.font: layout.dateFont, .foregroundColor: heated(mix((0.62, 0.72, 0.88), (0.93, 0.96, 1), skyLight.daylight))])
            ctx.restoreGState()

            drawShield(ctx, layout)
        }

        for sh in shards {
            let k = sh.age / sh.life
            let font = sh.bold ? NSFont.monospacedDigitSystemFont(ofSize: sh.fontSize * s, weight: .semibold)
                               : NSFont.systemFont(ofSize: sh.fontSize * s, weight: .medium)
            let color = NSColor(srgbRed: 1, green: lerp(0.55, 0.12, k), blue: lerp(0.15, 0.02, k), alpha: 1 - k * k)
            let str = sh.text as NSString
            let size = str.size(withAttributes: [.font: font])
            ctx.saveGState()
            ctx.translateBy(x: sh.x, y: sh.y)
            ctx.rotate(by: sh.angle)
            ctx.setShadow(offset: .zero, blur: 3 * s, color: rgb(1, 0.4, 0, 0.8 * (1 - k)))
            str.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: [.font: font, .foregroundColor: color])
            ctx.restoreGState()
        }
    }

    // MARK: Geometry

    // Horizontal figure-8 around the finger: two crossing diagonals through it, joined by end loops.
    private var loopRadius: CGFloat { 10 * scale }
    private var loopOffset: CGFloat { 80 * scale }   // finger to loop center

    private var figureEightParts: (line: CGFloat, arc: CGFloat, alpha: CGFloat) {
        let alpha = asin(loopRadius / loopOffset)
        return (2 * loopOffset * cos(alpha), loopRadius * (.pi + 2 * alpha), alpha)
    }

    private func figureEight(_ fx: CGFloat, _ u: CGFloat) -> (point: CGPoint, heading: CGFloat) {
        let (line, arc, alpha) = figureEightParts
        let total = 2 * (line + arc)
        var d = u.truncatingRemainder(dividingBy: total)
        if d < 0 { d += total }
        let A = loopOffset, R = loopRadius, my = midY
        let half = A * cos(alpha)
        if d < line {   // up-right through the finger
            let t = d - half
            return (CGPoint(x: fx + cos(alpha) * t, y: my + sin(alpha) * t), alpha)
        }
        d -= line
        if d < arc {    // clockwise around the right loop
            let a = .pi / 2 + alpha - d / R
            return (CGPoint(x: fx + A + R * cos(a), y: my + R * sin(a)), a - .pi / 2)
        }
        d -= arc
        if d < line {   // up-left through the finger
            let t = d - half
            return (CGPoint(x: fx - cos(alpha) * t, y: my + sin(alpha) * t), .pi - alpha)
        }
        d -= line
        let a = .pi / 2 - alpha + d / R   // counter-clockwise around the left loop
        return (CGPoint(x: fx - A + R * cos(a), y: my + R * sin(a)), a + .pi / 2)
    }

    /// Where to join the figure-8: the diagonal that heads toward its center from the dragon's side.
    private func figureEightEntry(_ fx: CGFloat) -> CGFloat {
        let (line, arc, _) = figureEightParts
        return head.x <= fx ? 0 : line + arc
    }

    /// Pure pursuit of a point running ahead of the dragon along the figure-8.
    private func pursueFigureEight(_ fx: CGFloat, _ u: inout CGFloat) -> (CGFloat, CGFloat) {
        let s = scale
        var rabbit = figureEight(fx, u).point
        var guardCount = 0
        while hypot(rabbit.x - head.x, rabbit.y - head.y) < 18 * s && guardCount < 200 {
            u += 1 * s
            rabbit = figureEight(fx, u).point
            guardCount += 1
        }
        let dist = hypot(rabbit.x - head.x, rabbit.y - head.y)
        return (atan2(rabbit.y - head.y, rabbit.x - head.x), dist > 60 * s ? 230 * s : 110 * s)
    }

    private func widthAt(_ u: CGFloat) -> CGFloat {
        if u < 0.1 { return lerp(2.2, 3.2, u / 0.1) }
        return max(0.45, 3.2 * (1 - pow((u - 0.1) / 0.9, 1.8)))
    }

    private func computeFrames(_ sp: inout Spine) {
        let n = sp.points.count
        sp.normals = []
        sp.back = []
        for i in 0..<n {
            let a = sp.points[max(i - 1, 0)], b = sp.points[min(i + 1, n - 1)]
            let len = max(hypot(b.x - a.x, b.y - a.y), 0.0001)
            let back = CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len)
            var nrm = CGPoint(x: -back.y, y: back.x)
            if nrm.y < 0 { nrm = CGPoint(x: -nrm.x, y: -nrm.y) }
            sp.back.append(back)
            sp.normals.append(nrm)
        }
    }

    /// Samples the body evenly by arc length along the head's trail.
    private func buildSpine() -> Spine {
        let s = scale
        var sp = Spine()
        let step = bodyLength / CGFloat(samples) * s
        let extra = Int(ceil(tuftLength / (bodyLength / CGFloat(samples))))
        let count = samples + extra + 1
        sp.bodyCount = samples + 1

        var pts: [CGPoint] = [head]
        var a = head
        var j = trail.count - 1
        var need = step
        var lastDir = CGPoint(x: -cos(heading), y: -sin(heading))
        while pts.count < count {
            let b = j >= 0 ? trail[j] : CGPoint(x: a.x + lastDir.x * step, y: a.y + lastDir.y * step)
            let seg = hypot(b.x - a.x, b.y - a.y)
            if seg < 0.0001 { j -= 1; continue }
            lastDir = CGPoint(x: (b.x - a.x) / seg, y: (b.y - a.y) / seg)
            if seg >= need {
                let p = CGPoint(x: a.x + lastDir.x * need, y: a.y + lastDir.y * need)
                pts.append(p)
                a = p
                need = step
            } else {
                need -= seg
                a = b
                j -= 1
            }
        }
        sp.points = pts
        sp.widths = (0..<count).map { widthAt(min(1, CGFloat($0) / CGFloat(samples))) * s }

        // A gentle travelling ripple so the body stays alive even while hovering.
        computeFrames(&sp)
        for i in 1..<count {
            let u = min(1, CGFloat(i) / CGFloat(samples))
            let amp = 0.9 * s * min(1, u / 0.25) * sin(time * 3 - CGFloat(i) * 0.25)
            sp.points[i].x += sp.normals[i].x * amp
            sp.points[i].y += sp.normals[i].y * amp
        }
        computeFrames(&sp)
        return sp
    }

    private func headTransform() -> CGAffineTransform {
        let s = scale
        // Nose dips a little while breathing fire.
        return CGAffineTransform(translationX: head.x, y: head.y)
            .rotated(by: heading - jaw * 0.12 * headFlip)
            .scaledBy(x: s, y: headFlip * s)
    }

    // MARK: Atmosphere

    enum Weather { case clear, cloudy, rain }

    private struct SkyLight {
        var daylight: CGFloat   // 0 night ... 1 full day
        var twilight: CGFloat   // peaks around sunrise / sunset
        var sunT: CGFloat       // 0 at sunrise ... 1 at sunset
        var elevation: CGFloat  // -1 ... 1
    }

    private struct Cloud {
        var x, y, scale, speed, threshold: CGFloat
        var near: Bool
        var puffs: [(dx: CGFloat, dy: CGFloat, r: CGFloat)]
    }

    private struct Drop { var x, y, vx, vy: CGFloat }
    private struct Splash { var x, age: CGFloat }
    private struct ShootingStar { var x, y, vx, vy, age, life: CGFloat }

    private typealias RGB = (CGFloat, CGFloat, CGFloat)

    private func mix(_ a: RGB, _ b: RGB, _ t: CGFloat) -> RGB {
        (lerp(a.0, b.0, t), lerp(a.1, b.1, t), lerp(a.2, b.2, t))
    }

    private func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// Sun position from local clock time, season and DST, assuming a mid-northern latitude.
    private func computeSkyLight(hour: CGFloat, dayOfYear: Int, dst: Bool) -> SkyLight {
        let lat: CGFloat = 40 * .pi / 180
        let decl = 23.44 * .pi / 180 * sin(2 * .pi * CGFloat(284 + dayOfYear) / 365)
        let w0 = acos(max(-1, min(1, -tan(lat) * tan(decl))))
        let dayLength = 2 * w0 * 180 / .pi / 15
        let noon: CGFloat = 12 + (dst ? 1 : 0)
        let sunrise = noon - dayLength / 2, sunset = noon + dayLength / 2
        var elevation: CGFloat
        var sunT: CGFloat
        if hour >= sunrise && hour <= sunset {
            sunT = (hour - sunrise) / dayLength
            elevation = sin(.pi * sunT)
        } else {
            var since = hour - sunset
            if since < 0 { since += 24 }
            elevation = -sin(.pi * since / (24 - dayLength))
            sunT = hour < sunrise ? 0 : 1
        }
        return SkyLight(daylight: smoothstep(-0.05, 0.3, elevation),
                        twilight: exp(-pow(elevation / 0.12, 2)),
                        sunT: sunT, elevation: elevation)
    }

    private func refreshSkyLight() {
        let now = Date()
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute, .second], from: now)
        let hour = skyHourOverride ?? (CGFloat(c.hour ?? 0) + CGFloat(c.minute ?? 0) / 60 + CGFloat(c.second ?? 0) / 3600)
        let day = cal.ordinality(of: .day, in: .year, for: now) ?? 180
        skyLight = computeSkyLight(hour: hour, dayOfYear: day, dst: TimeZone.current.isDaylightSavingTime(for: now))
    }

    private func makeClouds() {
        clouds = (0..<16).map { i in
            let near = i % 3 == 0
            let n = Int.random(in: 3...5)
            var puffs: [(dx: CGFloat, dy: CGFloat, r: CGFloat)] = []
            for k in 0..<n {
                let t = CGFloat(k) / CGFloat(max(n - 1, 1)) - 0.5
                let r = rand(3, 5.5) * (1 - abs(t) * 0.6)
                puffs.append((dx: t * CGFloat(n) * 4.2 + rand(-1, 1), dy: rand(0, 1.8) + (1 - abs(t) * 2) * 1.5, r: r))
            }
            return Cloud(x: rand(0, 1), y: rand(0.5, 0.88), scale: near ? rand(1.15, 1.45) : rand(0.75, 1.0),
                         speed: near ? rand(6, 10) : rand(2.5, 5), threshold: CGFloat(i) / 16 + rand(-0.03, 0.03),
                         near: near, puffs: puffs)
        }
    }

    private func chooseWeather() {
        let roll = CGFloat.random(in: 0...1)
        weather = roll < 0.55 ? .clear : roll < 0.85 ? .cloudy : .rain
        weatherTimer = weather == .rain ? rand(60, 150) : rand(180, 420)
    }

    private func updateAtmosphere(_ dt: CGFloat) {
        let s = scale
        skyRefreshIn -= dt
        if skyRefreshIn <= 0 { refreshSkyLight(); skyRefreshIn = 1 }

        if !weatherLocked {
            weatherTimer -= dt
            if weatherTimer <= 0 { chooseWeather() }
        }
        let cloudTarget: CGFloat = weather == .clear ? 0.28 : weather == .cloudy ? 0.75 : 1.0
        let rainTarget: CGFloat = weather == .rain ? 1 : 0
        cloudAmount += (cloudTarget - cloudAmount) * min(1, dt * 0.06)
        rainAmount += (rainTarget - rainAmount) * min(1, dt * (rainTarget > rainAmount ? 0.05 : 0.12))

        let span = bounds.width + 80 * s
        for i in clouds.indices {
            clouds[i].x += clouds[i].speed * s * dt / span
            if clouds[i].x > 1 { clouds[i].x -= 1 }
        }

        // Rain
        if rainAmount > 0.05 {
            dropCarry += dt * 700 * rainAmount * (bounds.width / 1085)
            while dropCarry >= 1 {
                dropCarry -= 1
                drops.append(Drop(x: rand(0, bounds.width + 30 * s), y: bounds.height + rand(0, 6) * s,
                                  vx: -45 * s, vy: -rand(170, 230) * s))
            }
        }
        drops = drops.compactMap { d in
            var d = d
            d.x += d.vx * dt
            d.y += d.vy * dt
            if d.y < 0.5 * s {
                if CGFloat.random(in: 0...1) < 0.5 { splashes.append(Splash(x: d.x, age: 0)) }
                return nil
            }
            return d
        }
        splashes = splashes.compactMap { sp in
            var sp = sp
            sp.age += dt
            return sp.age < 0.22 ? sp : nil
        }

        // Lightning in heavy rain
        if rainAmount > 0.6 {
            lightningTimer -= dt
            if lightningTimer <= 0 {
                strikeLightning()
                lightningTimer = rand(12, 35)
            }
        }
        boltAge += dt

        // Shooting stars on clear nights
        if skyLight.daylight < 0.2 && cloudAmount < 0.5 {
            shootingTimer -= dt
            if shootingTimer <= 0 {
                let dir: CGFloat = Bool.random() ? 1 : -1
                shootingStars.append(ShootingStar(x: rand(0.15, 0.85) * bounds.width, y: bounds.height * rand(0.75, 0.95),
                                                  vx: dir * rand(180, 260) * s, vy: -rand(40, 70) * s, age: 0, life: rand(0.5, 0.8)))
                shootingTimer = rand(7, 20)
            }
        }
        shootingStars = shootingStars.compactMap { st in
            var st = st
            st.age += dt
            st.x += st.vx * dt
            st.y += st.vy * dt
            return st.age < st.life ? st : nil
        }
    }

    private func strikeLightning() {
        let s = scale
        var x = rand(0.1, 0.9) * bounds.width
        var y = bounds.height
        var pts = [CGPoint(x: x, y: y)]
        while y > 0 {
            y -= rand(2.5, 5) * s
            x += rand(-4, 4) * s
            pts.append(CGPoint(x: x, y: max(y, 0)))
        }
        bolt = pts
        boltAge = 0
    }

    private var lightningFlash: CGFloat {
        guard !bolt.isEmpty, boltAge < 0.45 else { return 0 }
        let flicker: CGFloat = (boltAge > 0.07 && boltAge < 0.12) ? 0.25 : 1
        return max(0, 1 - boltAge / 0.45) * flicker
    }

    /// 0 = clear sky, 1 = fully overcast.
    private var overcast: CGFloat { max(0, min(1, (cloudAmount - 0.4) / 0.6)) }

    private func drawSky(_ ctx: CGContext) {
        let s = scale
        let w = bounds.width, h = bounds.height
        let L = skyLight
        let oc = overcast

        // Gradient
        var top = mix((0, 0, 0), (0.10, 0.36, 0.72), L.daylight)
        var bottom = mix((0.02, 0.03, 0.07), (0.40, 0.63, 0.90), L.daylight)
        top = mix(top, (0.22, 0.16, 0.40), L.twilight * 0.6)
        bottom = mix(bottom, (0.98, 0.52, 0.30), L.twilight * 0.85)
        let greyTop = mix((0.03, 0.03, 0.05), (0.36, 0.40, 0.46), L.daylight)
        let greyBottom = mix((0.07, 0.08, 0.10), (0.52, 0.55, 0.60), L.daylight)
        top = mix(top, greyTop, oc * 0.85)
        bottom = mix(bottom, greyBottom, oc * 0.85)
        let dim = 1 - 0.3 * rainAmount
        top = (top.0 * dim, top.1 * dim, top.2 * dim)
        bottom = (bottom.0 * dim, bottom.1 * dim, bottom.2 * dim)
        let colors = [rgb(top.0, top.1, top.2), rgb(bottom.0, bottom.1, bottom.2)] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: .zero, options: [])
        }

        // Stars
        let starAlpha = (1 - L.daylight) * (1 - oc * 0.9) * (1 - L.twilight * 0.4)
        if starAlpha > 0.01 {
            ctx.saveGState()
            ctx.setBlendMode(.plusLighter)
            ctx.setLineCap(.round)
            for st in stars {
                // Steady glow most of the time, with a sharp bright flash at each twinkle peak.
                let wave = 0.5 + 0.5 * sin(time * st.speed + st.phase)
                let twinkle = pow(wave, 3)
                let a = min(1, 0.55 + 0.45 * twinkle) * starAlpha
                let c = CGPoint(x: st.x * w, y: st.y * h)
                let r = (0.45 + st.r * 0.75) * s * (0.85 + 0.4 * twinkle)
                let tint: RGB = st.phase < 1.2 ? (1, 0.9, 0.75) : st.phase > 5.2 ? (0.75, 0.85, 1) : (0.92, 0.95, 1)

                ctx.setFillColor(rgb(tint.0 * 0.8, tint.1 * 0.85, tint.2, 0.22 * a))
                let halo = r * 2.8
                ctx.fillEllipse(in: CGRect(x: c.x - halo, y: c.y - halo, width: halo * 2, height: halo * 2))
                ctx.setFillColor(rgb(tint.0, tint.1, tint.2, a))
                ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))

                if st.r > 0.5 && twinkle > 0.3 {
                    let len = r * (2 + 5 * twinkle)
                    ctx.setStrokeColor(rgb(tint.0, tint.1, tint.2, a * twinkle))
                    ctx.setLineWidth(0.35 * s)
                    ctx.move(to: CGPoint(x: c.x - len, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + len, y: c.y))
                    ctx.move(to: CGPoint(x: c.x, y: c.y - len * 0.7)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + len * 0.7))
                    ctx.strokePath()
                }
            }
            ctx.restoreGState()
            ctx.saveGState()
            ctx.setLineCap(.round)
            for st in shootingStars {
                let k = st.age / st.life
                let a = sin(k * .pi) * starAlpha
                ctx.setStrokeColor(rgb(1, 1, 1, a))
                ctx.setLineWidth(0.7 * s)
                ctx.move(to: CGPoint(x: st.x, y: st.y))
                ctx.addLine(to: CGPoint(x: st.x - st.vx * 0.08, y: st.y - st.vy * 0.08))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }

        // Moon
        let moonAlpha = (1 - L.daylight) * (1 - oc * 0.85)
        if moonAlpha > 0.01 {
            let mx = w * 0.82, my = h * 0.62, mr = h * 0.2
            let disc = CGRect(x: mx - mr, y: my - mr, width: mr * 2, height: mr * 2)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6 * s, color: rgb(1, 0.95, 0.75, 0.5 * moonAlpha))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.addEllipse(in: disc)
            ctx.clip()
            ctx.addEllipse(in: disc)
            ctx.addEllipse(in: disc.offsetBy(dx: mr * 0.5, dy: mr * 0.3))
            ctx.clip(using: .evenOdd)   // disc minus the shadowed bite
            ctx.setFillColor(rgb(1, 0.95, 0.78, 0.85 * moonAlpha))
            ctx.fill(disc)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        // Sun, gliding from sunrise (left) to sunset (right)
        let sunAlpha = smoothstep(-0.08, 0.05, L.elevation) * (1 - oc * 0.9)
        if sunAlpha > 0.01 {
            let c = CGPoint(x: lerp(0.1, 0.9, L.sunT) * w, y: h * (0.18 + 0.6 * max(L.elevation, 0)))
            let warm = 1 - smoothstep(0, 0.35, L.elevation)
            let core = mix((1, 0.97, 0.82), (1, 0.6, 0.25), warm)
            let glowColors = [rgb(core.0, core.1, core.2 * 0.8, 0.55 * sunAlpha), rgb(core.0, core.1, core.2, 0)] as CFArray
            ctx.saveGState()
            ctx.setBlendMode(.plusLighter)
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: glowColors, locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 32 * s, options: [])
            }
            // Slowly turning rays
            ctx.setStrokeColor(rgb(core.0, core.1, core.2, 0.35 * sunAlpha))
            ctx.setLineWidth(0.8 * s)
            ctx.setLineCap(.round)
            for k in 0..<10 {
                let a = time * 0.25 + CGFloat(k) * .pi / 5
                ctx.move(to: CGPoint(x: c.x + cos(a) * 7 * s, y: c.y + sin(a) * 7 * s))
                ctx.addLine(to: CGPoint(x: c.x + cos(a) * 10.5 * s, y: c.y + sin(a) * 10.5 * s))
            }
            ctx.strokePath()
            ctx.restoreGState()
            ctx.setFillColor(rgb(core.0, core.1, core.2, sunAlpha))
            ctx.fillEllipse(in: CGRect(x: c.x - 5 * s, y: c.y - 5 * s, width: 10 * s, height: 10 * s))
        }

        drawClouds(ctx, near: false)

        // Lightning lights up the whole sky
        let flash = lightningFlash
        if flash > 0 {
            ctx.setFillColor(rgb(0.85, 0.88, 1, 0.4 * flash))
            ctx.fill(bounds)
            ctx.saveGState()
            ctx.setBlendMode(.plusLighter)
            ctx.setShadow(offset: .zero, blur: 5 * s, color: rgb(0.7, 0.8, 1, flash))
            ctx.setStrokeColor(rgb(0.95, 0.97, 1, flash))
            ctx.setLineWidth(1.1 * s)
            ctx.setLineJoin(.round)
            ctx.addLines(between: bolt)
            ctx.strokePath()
            ctx.restoreGState()
        }

        drawClouds(ctx, near: true)
    }

    private func drawClouds(_ ctx: CGContext, near: Bool) {
        let s = scale
        let L = skyLight
        let oc = overcast
        let span = bounds.width + 80 * s
        // Bright white by day, grey when overcast, dim blue-grey at night, warm at twilight.
        var main = mix(mix((0.15, 0.17, 0.23), (0.98, 0.98, 1.0), L.daylight), mix((0.09, 0.10, 0.13), (0.62, 0.65, 0.70), L.daylight), oc)
        var shade = mix(mix((0.09, 0.10, 0.14), (0.80, 0.84, 0.90), L.daylight), mix((0.05, 0.06, 0.08), (0.45, 0.48, 0.53), L.daylight), oc)
        main = mix(main, (1, 0.72, 0.58), L.twilight * 0.5 * (1 - oc))
        shade = mix(shade, (0.75, 0.45, 0.45), L.twilight * 0.4 * (1 - oc))
        if lightningFlash > 0 {
            main = mix(main, (0.95, 0.95, 1), lightningFlash * 0.6)
            shade = mix(shade, (0.75, 0.77, 0.85), lightningFlash * 0.6)
        }

        for c in clouds where c.near == near {
            let vis = max(0, min(1, (cloudAmount - c.threshold) / 0.12))
            guard vis > 0.01 else { continue }
            let cx = c.x * span - 40 * s
            let cy = c.y * bounds.height
            let k = c.scale * s * (1 + 0.25 * rainAmount)
            ctx.saveGState()
            ctx.setAlpha(vis * (near ? 0.95 : 0.75))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setFillColor(rgb(shade.0, shade.1, shade.2))
            for p in c.puffs {
                ctx.fillEllipse(in: CGRect(x: cx + (p.dx - p.r) * k, y: cy + (p.dy - p.r - 0.9) * k, width: p.r * 2 * k, height: p.r * 2 * k))
            }
            ctx.setFillColor(rgb(main.0, main.1, main.2))
            for p in c.puffs {
                ctx.fillEllipse(in: CGRect(x: cx + (p.dx - p.r * 0.92) * k, y: cy + (p.dy - p.r * 0.8) * k,
                                           width: p.r * 1.84 * k, height: p.r * 1.84 * k))
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }

    /// Rain falls in front of everything except the fire.
    private func drawRain(_ ctx: CGContext) {
        guard !drops.isEmpty || !splashes.isEmpty else { return }
        let s = scale
        let a = 0.25 + 0.3 * rainAmount
        ctx.saveGState()
        ctx.setStrokeColor(rgb(0.78, 0.86, 1, a))
        ctx.setLineWidth(0.5 * s)
        ctx.setLineCap(.round)
        for d in drops {
            ctx.move(to: CGPoint(x: d.x, y: d.y))
            ctx.addLine(to: CGPoint(x: d.x - d.vx * 0.025, y: d.y - d.vy * 0.025))
        }
        ctx.strokePath()
        ctx.setLineWidth(0.4 * s)
        for sp in splashes {
            let k = sp.age / 0.22
            let r = (0.8 + 2.2 * k) * s
            ctx.setStrokeColor(rgb(0.8, 0.88, 1, a * (1 - k)))
            ctx.strokeEllipse(in: CGRect(x: sp.x - r, y: 0.3 * s, width: r * 2, height: r * 0.7))
        }
        ctx.restoreGState()
    }

    func debugSetSky(hour: CGFloat, weather w: Weather) {
        skyHourOverride = hour
        weather = w
        weatherLocked = true
        cloudAmount = w == .clear ? 0.28 : w == .cloudy ? 0.75 : 1.0
        rainAmount = w == .rain ? 1 : 0
        refreshSkyLight()
    }

    func debugStrike() { strikeLightning() }

    // MARK: Feeding

    private var feedButtonRect: CGRect {
        let s = scale
        return CGRect(x: bounds.width - 38 * s, y: 3 * s, width: 34 * s, height: 24 * s)
    }

    private var thankX: CGFloat = 0

    func feed() {
        guard feedCooldown <= 0, chick == nil else { return }
        let s = scale
        let b = feedButtonRect
        let start = CGPoint(x: b.minX - 4 * s, y: b.midY)
        chick = Chick(pos: start, vel: CGPoint(x: -60 * s, y: 25 * s), target: CGPoint(x: b.minX - 120 * s, y: midY + 6 * s),
                      retargetIn: rand(0.8, 1.6))
        feedCooldown = feedCooldownDuration
        buttonPress = 1
        thanking = false
        // A puff of feathers as it pops out
        for _ in 0..<5 { spawnFluff(at: start) }
    }

    private func spawnHeart(at p: CGPoint? = nil, burst: Bool = false) {
        let s = scale
        let origin = p ?? CGPoint(x: 6, y: 3).applying(headTransform())
        hearts.append(Heart(x: origin.x + rand(-2, 2) * s, y: origin.y + rand(-1, 2) * s,
                            vx: (burst ? rand(-30, 30) : rand(-8, 8)) * s, vy: (burst ? rand(15, 40) : rand(10, 22)) * s,
                            age: 0, life: rand(1.4, 2.4), size: rand(2.2, 3.4) * s, phase: rand(0, 2 * .pi)))
    }

    private func spawnFluff(at p: CGPoint) {
        let s = scale
        let a = rand(0, 2 * .pi), v = rand(10, 40) * s
        fluff.append(Fluff(x: p.x, y: p.y, vx: cos(a) * v, vy: sin(a) * v, age: 0, life: rand(0.8, 1.4), angle: rand(0, .pi)))
    }

    private func updateFeeding(_ dt: CGFloat) {
        let s = scale
        if feedCooldown > 0 {
            feedCooldown -= dt
            if feedCooldown <= 0 { feedReadyPulse = 1 }
        }
        feedReadyPulse = max(0, feedReadyPulse - dt * 1.5)
        buttonPress = max(0, buttonPress - dt * 5)

        if var c = chick {
            c.age += dt
            c.flap += dt * 28
            c.retargetIn -= dt
            c.dodgeCooldown -= dt
            c.boost -= dt
            let tired = max(0.5, 1 - c.age / 55)   // wears down slowly; it always gets caught eventually
            let exhausted = c.age > 45
            let lo = CGPoint(x: 15 * s, y: 6 * s), hi = CGPoint(x: feedButtonRect.minX - 10 * s, y: bounds.height - 6 * s)
            func clampX(_ x: CGFloat) -> CGFloat { min(max(x, lo.x), hi.x) }

            let toDragon = CGPoint(x: c.pos.x - head.x, y: c.pos.y - head.y)
            let dragonDist = hypot(toDragon.x, toDragon.y)
            let approaching = (toDragon.x * cos(heading) + toDragon.y * sin(heading)) > dragonDist * 0.4
            c.fear = max(0, min(1, 1 - (dragonDist - 12 * s) / (63 * s)))

            // React by time-to-contact so a fast head-on approach still gets dodged.
            let dragonVel = CGPoint(x: cos(heading) * currentSpeed, y: sin(heading) * currentSpeed)
            let closing = ((dragonVel.x - c.vel.x) * toDragon.x + (dragonVel.y - c.vel.y) * toDragon.y) / max(dragonDist, 0.001)
            let threatened = dragonDist < 45 * s || (closing > 0 && dragonDist / closing < 0.5)
            if threatened && approaching && c.dodgeCooldown <= 0
                && CGFloat.random(in: 0...1) < (exhausted ? 0.25 : 0.92) {
                // Juke over or under the dragon. Head-on: zoom on past it so it has to turn around.
                // Otherwise burst away, unless cornered against an edge, then double back past it.
                let away: CGFloat = toDragon.x >= 0 ? 1 : -1
                let headOn = c.vel.x * away < 0
                let cornered = (away > 0 && hi.x - c.pos.x < 50 * s) || (away < 0 && c.pos.x - lo.x < 50 * s)
                let dirX = (headOn || cornered) ? -away : away
                let dragonAbove = head.y > c.pos.y
                c.target = CGPoint(x: clampX(c.pos.x + dirX * rand(70, 150) * s),
                                   y: dragonAbove ? rand(lo.y, lo.y + 4 * s) : rand(hi.y - 4 * s, hi.y))
                c.dodgeCooldown = rand(0.3, 0.6) + (1 - tired) * 0.9
                c.boost = 0.45
                c.retargetIn = rand(0.8, 1.6)
            } else if dragonDist < 90 * s && approaching && !exhausted && c.boost <= 0 {
                // Keep drifting away while the dragon lines up.
                let away: CGFloat = toDragon.x >= 0 ? 1 : -1
                if abs(c.target.x - c.pos.x) < 20 * s || (c.target.x - c.pos.x) * away < 0 {
                    c.target = CGPoint(x: clampX(c.pos.x + away * rand(40, 80) * s), y: rand(lo.y, hi.y))
                }
            } else if c.retargetIn <= 0 || hypot(c.target.x - c.pos.x, c.target.y - c.pos.y) < 6 * s {
                c.target = CGPoint(x: rand(lo.x, hi.x), y: rand(lo.y, hi.y))
                c.retargetIn = rand(1.0, 2.5)
            }

            let dx = c.target.x - c.pos.x, dy = c.target.y - c.pos.y
            let len = max(hypot(dx, dy), 0.001)
            let v = 95 * s * tired * (c.boost > 0 ? 1.9 : 1)
            let accel = min(1, dt * (c.boost > 0 ? 7 : 3.5))
            c.vel.x += (dx / len * v - c.vel.x) * accel
            c.vel.y += (dy / len * v - c.vel.y) * accel
            c.pos.x += c.vel.x * dt
            c.pos.y += (c.vel.y + sin(c.flap) * 14 * s) * dt
            c.pos.x = min(max(c.pos.x, 4 * s), bounds.width - 4 * s)
            c.pos.y = min(max(c.pos.y, 4 * s), bounds.height - 4 * s)
            c.flap += dt * 20 * c.fear   // flaps harder when scared

            // Nervous sweat, faster the closer the dragon gets
            if c.fear > 0 {
                c.sweatCarry += dt * (3 + 22 * c.fear * c.fear)
                while c.sweatCarry >= 1 {
                    c.sweatCarry -= 1
                    let facing: CGFloat = c.vel.x >= 0 ? 1 : -1
                    let side: CGFloat = Bool.random() ? 1 : -1
                    sweat.append(Sweat(x: c.pos.x + facing * 2.4 * s + side * 1.5 * s, y: c.pos.y + 3.6 * s,
                                       vx: side * rand(12, 28) * s + c.vel.x * 0.3, vy: rand(18, 34) * s,
                                       age: 0, life: rand(0.45, 0.7)))
                }
            }

            // Chomp! The first two snaps always miss; after that the odds climb as the chick tires.
            chompCooldown -= dt
            let mouth = CGPoint(x: 11, y: -2.4).applying(headTransform())
            let inReach = hypot(mouth.x - c.pos.x, mouth.y - c.pos.y) < 6 * s && jaw > 0.4 && chompCooldown <= 0
            if inReach && (c.misses < 2 || CGFloat.random(in: 0...1) >= min(1, 0.1 + c.age / 35)) {
                c.misses += 1
                // Missed! Jaws clap shut, a couple of feathers fly, the chick bolts.
                jaw = 0
                hungryJaw = false
                chompCooldown = rand(0.6, 0.9)
                for _ in 0..<3 { spawnFluff(at: c.pos) }
                let away: CGFloat = c.pos.x >= head.x ? 1 : -1
                let lo = 6 * s, hi = bounds.height - 6 * s
                c.target = CGPoint(x: min(max(c.pos.x + away * rand(90, 160) * s, 15 * s), feedButtonRect.minX - 10 * s),
                                   y: c.pos.y > midY ? rand(lo, lo + 4 * s) : rand(hi - 4 * s, hi))
                c.boost = 0.6
                c.dodgeCooldown = 0.3
                c.retargetIn = rand(1.0, 1.8)
                chick = c
            } else if inReach {
                chick = nil
                jaw = 0
                hungryJaw = false
                for _ in 0..<10 { spawnFluff(at: c.pos) }
                for _ in 0..<9 { spawnHeart(burst: true) }
                thanking = true
                // Center the figure-8 on the spot (kept clear of the edges and the button),
                // joining at its crossing point in the direction the dragon is already flying.
                let reach = loopOffset + loopRadius + 6 * s
                thankX = min(max(c.pos.x, reach), feedButtonRect.minX - reach)
                let (line, arc, _) = figureEightParts
                thankU = cos(heading) >= 0 ? line / 2 : line + arc + line / 2
                thankEndU = thankU + 2 * (line + arc) + 40 * s
                debugLog?("eaten at \(time)")
            } else {
                chick = c
            }
        }

        hearts = hearts.compactMap { h in
            var h = h
            h.age += dt
            guard h.age < h.life else { return nil }
            h.vx *= pow(0.3, dt)
            h.x += (h.vx + sin(h.age * 4 + h.phase) * 6 * s) * dt
            h.y += h.vy * dt
            return h
        }
        sweat = sweat.compactMap { d in
            var d = d
            d.age += dt
            guard d.age < d.life else { return nil }
            d.vy -= 110 * s * dt
            d.x += d.vx * dt
            d.y += d.vy * dt
            return d
        }
        fluff = fluff.compactMap { f in
            var f = f
            f.age += dt
            guard f.age < f.life else { return nil }
            f.vx *= pow(0.2, dt)
            f.vy = f.vy * pow(0.2, dt) - 8 * s * dt
            f.x += (f.vx + sin(f.age * 6 + f.angle) * 4 * s) * dt
            f.y += f.vy * dt
            f.angle += dt * 3
            return f
        }
    }

    private func drawChick(_ ctx: CGContext, _ c: Chick) {
        let s = scale
        let facing: CGFloat = c.vel.x >= 0 ? 1 : -1
        ctx.saveGState()
        ctx.translateBy(x: c.pos.x, y: c.pos.y)
        ctx.scaleBy(x: facing * s, y: s)
        // Feet
        ctx.setStrokeColor(rgb(1, 0.55, 0.1))
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: -0.6, y: -2.4)); ctx.addLine(to: CGPoint(x: -0.9, y: -3.6))
        ctx.move(to: CGPoint(x: 0.6, y: -2.4)); ctx.addLine(to: CGPoint(x: 0.5, y: -3.6))
        ctx.strokePath()
        // Body + head
        ctx.setFillColor(rgb(1, 0.86, 0.25))
        ctx.fillEllipse(in: CGRect(x: -3, y: -2.7, width: 5.6, height: 5))
        ctx.fillEllipse(in: CGRect(x: 0.6, y: 0.4, width: 3.8, height: 3.6))
        // Beak
        ctx.setFillColor(rgb(1, 0.55, 0.1))
        let beak = CGMutablePath()
        beak.addPolygon([CGPoint(x: 4.2, y: 2.6), CGPoint(x: 5.8, y: 2.0), CGPoint(x: 4.2, y: 1.5)])
        ctx.addPath(beak)
        ctx.fillPath()
        // Eye: goes wide when the dragon is close
        if c.fear > 0.35 {
            ctx.setFillColor(rgb(1, 1, 1))
            ctx.fillEllipse(in: CGRect(x: 2.5, y: 1.9, width: 1.6, height: 1.7))
            ctx.setFillColor(rgb(0.1, 0.05, 0))
            ctx.fillEllipse(in: CGRect(x: 3.1, y: 2.4, width: 0.6, height: 0.7))
        } else {
            ctx.setFillColor(rgb(0.1, 0.05, 0))
            ctx.fillEllipse(in: CGRect(x: 2.9, y: 2.3, width: 0.8, height: 0.9))
        }
        // Flapping wing
        ctx.saveGState()
        ctx.translateBy(x: -0.6, y: 0.6)
        ctx.rotate(by: sin(c.flap) * 0.9 + 0.3)
        ctx.setFillColor(rgb(1, 0.75, 0.15))
        ctx.fillEllipse(in: CGRect(x: -3.2, y: -0.8, width: 3.6, height: 1.8))
        ctx.restoreGState()
        ctx.restoreGState()
    }

    private func heartPath(_ c: CGPoint, _ r: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x, y: c.y - 0.9 * r))
        p.addCurve(to: CGPoint(x: c.x - r, y: c.y + 0.25 * r),
                   control1: CGPoint(x: c.x - 0.35 * r, y: c.y - 0.45 * r), control2: CGPoint(x: c.x - r, y: c.y - 0.25 * r))
        p.addCurve(to: CGPoint(x: c.x, y: c.y + 0.55 * r),
                   control1: CGPoint(x: c.x - r, y: c.y + 0.85 * r), control2: CGPoint(x: c.x - 0.1 * r, y: c.y + 0.95 * r))
        p.addCurve(to: CGPoint(x: c.x + r, y: c.y + 0.25 * r),
                   control1: CGPoint(x: c.x + 0.1 * r, y: c.y + 0.95 * r), control2: CGPoint(x: c.x + r, y: c.y + 0.85 * r))
        p.addCurve(to: CGPoint(x: c.x, y: c.y - 0.9 * r),
                   control1: CGPoint(x: c.x + r, y: c.y - 0.25 * r), control2: CGPoint(x: c.x + 0.35 * r, y: c.y - 0.45 * r))
        p.closeSubpath()
        return p
    }

    private func drawHeartsAndFluff(_ ctx: CGContext) {
        let s = scale
        for d in sweat {
            // Teardrop pointing along its motion
            let k = d.age / d.life
            let a = k < 0.7 ? 1 : 1 - (k - 0.7) / 0.3
            ctx.saveGState()
            ctx.translateBy(x: d.x, y: d.y)
            ctx.rotate(by: atan2(d.vy, d.vx) - .pi / 2)
            let r = 0.95 * s
            let drop = CGMutablePath()
            drop.move(to: CGPoint(x: 0, y: r * 2.3))
            drop.addCurve(to: CGPoint(x: 0, y: -r), control1: CGPoint(x: r * 1.4, y: r * 0.4), control2: CGPoint(x: r * 1.2, y: -r))
            drop.addCurve(to: CGPoint(x: 0, y: r * 2.3), control1: CGPoint(x: -r * 1.2, y: -r), control2: CGPoint(x: -r * 1.4, y: r * 0.4))
            ctx.addPath(drop)
            ctx.setFillColor(rgb(0.5, 0.8, 1, a))
            ctx.fillPath()
            ctx.setFillColor(rgb(1, 1, 1, 0.8 * a))
            ctx.fillEllipse(in: CGRect(x: -r * 0.45, y: -r * 0.1, width: r * 0.5, height: r * 0.6))
            ctx.restoreGState()
        }
        for f in fluff {
            let k = f.age / f.life
            ctx.saveGState()
            ctx.translateBy(x: f.x, y: f.y)
            ctx.rotate(by: f.angle)
            ctx.setFillColor(rgb(1, 0.9, 0.45, 1 - k))
            ctx.fillEllipse(in: CGRect(x: -1.1 * s, y: -0.4 * s, width: 2.2 * s, height: 0.8 * s))
            ctx.restoreGState()
        }
        for h in hearts {
            let k = h.age / h.life
            let pop = min(1, h.age * 6)                // pops in
            let r = h.size * pop * (1 + 0.08 * sin(h.age * 10))
            let a = k < 0.6 ? 1 : 1 - (k - 0.6) / 0.4
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 3 * s, color: rgb(1, 0.3, 0.5, 0.8 * a))
            ctx.addPath(heartPath(CGPoint(x: h.x, y: h.y), r))
            ctx.setFillColor(rgb(1, 0.32, 0.5, a))
            ctx.fillPath()
            ctx.restoreGState()
            // Shine
            ctx.setFillColor(rgb(1, 0.8, 0.85, 0.7 * a))
            ctx.fillEllipse(in: CGRect(x: h.x - 0.6 * r, y: h.y + 0.05 * r, width: 0.35 * r, height: 0.3 * r))
        }
    }

    private func drawFeedButton(_ ctx: CGContext) {
        let s = scale
        var b = feedButtonRect
        let squish = 1 - 0.1 * buttonPress
        b = b.insetBy(dx: b.width * (1 - squish) / 2, dy: b.height * (1 - squish) / 2)
        let shape = CGPath(roundedRect: b, cornerWidth: 6 * s, cornerHeight: 6 * s, transform: nil)
        let ready = feedCooldown <= 0 && chick == nil

        ctx.addPath(shape)
        ctx.setFillColor(rgb(0.2, 0.2, 0.22))
        ctx.fillPath()

        let emoji = "🐔" as NSString
        let font = NSFont.systemFont(ofSize: 12.5 * s * squish)
        let size = emoji.size(withAttributes: [.font: font])
        ctx.saveGState()
        ctx.setAlpha(ready ? 1 : 0.35)
        // Emoji line boxes sit high; drop it a bit to center the artwork.
        emoji.draw(at: CGPoint(x: b.midX - size.width / 2, y: b.midY - size.height / 2 - 1.5 * s * squish),
                   withAttributes: [.font: font])
        ctx.restoreGState()

        if feedCooldown > 0 {
            // Clock-wipe of the time remaining
            let frac = feedCooldown / feedCooldownDuration
            let c = CGPoint(x: b.midX, y: b.midY)
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            ctx.move(to: c)
            ctx.addArc(center: c, radius: b.width, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * frac, clockwise: true)
            ctx.closePath()
            ctx.setFillColor(rgb(0, 0, 0, 0.45))
            ctx.fillPath()
            ctx.restoreGState()
        }
        if feedReadyPulse > 0 {
            ctx.saveGState()
            ctx.setBlendMode(.plusLighter)
            let grow = (1 - feedReadyPulse) * 4 * s
            ctx.addPath(CGPath(roundedRect: b.insetBy(dx: -grow, dy: -grow * 0.5), cornerWidth: 7 * s, cornerHeight: 7 * s, transform: nil))
            ctx.setStrokeColor(rgb(1, 0.85, 0.4, feedReadyPulse))
            ctx.setLineWidth(1.2 * s)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // MARK: Touches

    override func touchesBegan(with event: NSEvent) {
        if let t = event.touches(matching: .began, in: self).first,
           feedButtonRect.insetBy(dx: -4 * scale, dy: -4 * scale).contains(t.location(in: self)) {
            buttonTouch = true
            feed()
            return
        }
        let now = CACurrentMediaTime()
        if now - lastTap < 0.3 {
            lastTap = 0
            fingerDown = false
            chaseX = nil
            onDoubleTap?()
            return
        }
        lastTap = now
        if let t = event.touches(matching: .began, in: self).first {
            chaseX = t.location(in: self).x
        }
        fingerDown = true
        eagerFire = true
    }

    override func touchesMoved(with event: NSEvent) {
        if buttonTouch { return }
        if let t = event.touches(matching: .moved, in: self).first {
            chaseX = t.location(in: self).x
        }
    }

    override func touchesEnded(with event: NSEvent) {
        if buttonTouch { buttonTouch = false; return }
        fingerDown = false
        chaseUntil = time + 1.2
    }

    override func touchesCancelled(with event: NSEvent) {
        touchesEnded(with: event)
    }

    private func drawFingerMarker(_ ctx: CGContext) {
        guard let fx = chaseX else { return }
        let s = scale
        let c = CGPoint(x: fx, y: midY)
        let fade: CGFloat = fingerDown ? 1 : max(0, (chaseUntil - time) / 1.2)
        if heat > 0.01 {
            let colors = [rgb(1, 0.6, 0.15, 0.6 * heat * fade), rgb(1, 0.25, 0, 0)] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                ctx.saveGState()
                ctx.setBlendMode(.plusLighter)
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 16 * s, options: [])
                ctx.restoreGState()
            }
        }
        let r = (6 + sin(time * 6) * 0.6) * s
        ctx.setStrokeColor(rgb(1, lerp(1, 0.6, heat), lerp(1, 0.2, heat), 0.45 * fade))
        ctx.setLineWidth(1 * s)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(rgb(0, 0, 0))
        ctx.fill(bounds)

        drawSky(ctx)
        drawFireGlow(ctx)

        let sp = buildSpine()
        drawClock(ctx)
        drawLegs(ctx, sp, near: false)
        drawTailTuft(ctx, sp)
        drawFins(ctx, sp)
        drawBody(ctx, sp)
        drawLegs(ctx, sp, near: true)
        drawMane(ctx, sp)

        ctx.saveGState()
        ctx.concatenate(headTransform())
        drawHead(ctx)
        ctx.restoreGState()

        if let c = chick { drawChick(ctx, c) }
        drawRain(ctx)
        drawFingerMarker(ctx)
        drawParticles(ctx)
        drawHeartsAndFluff(ctx)
        drawFeedButton(ctx)
    }

    private func drawFireGlow(_ ctx: CGContext) {
        let intensity = min(1, CGFloat(particles.count) / 120) * (0.85 + 0.15 * sin(time * 40))
        guard intensity > 0.01 else { return }
        let center = CGPoint(x: 18, y: -2).applying(headTransform())
        let colors = [rgb(1, 0.55, 0.1, 0.35 * intensity), rgb(1, 0.3, 0.0, 0)] as CFArray
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])
        else { return }
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center,
                               endRadius: 55 * scale, options: [])
        ctx.restoreGState()
    }

    private func drawParticles(_ ctx: CGContext) {
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        for p in particles {
            let k = p.age / p.life
            let color: CGColor
            let size: CGFloat
            if p.ember {
                let flicker = 0.6 + 0.4 * sin(time * 30 + p.x)
                color = rgb(1, 0.6, 0.15, (1 - k) * flicker)
                size = p.size
            } else {
                size = p.size * (1 + k * 2.6)
                let a = pow(1 - k, 1.3) * 0.75
                switch k {
                case ..<0.12: color = rgb(1, 1, 0.85, a)
                case ..<0.35:
                    let u = (k - 0.12) / 0.23
                    color = rgb(1, lerp(1, 0.78, u), lerp(0.85, 0.2, u), a)
                case ..<0.65:
                    let u = (k - 0.35) / 0.3
                    color = rgb(1, lerp(0.78, 0.32, u), lerp(0.2, 0.04, u), a)
                default:
                    let u = (k - 0.65) / 0.35
                    color = rgb(lerp(1, 0.55, u), lerp(0.32, 0.06, u), 0.03, a)
                }
            }
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2))
        }
        ctx.restoreGState()
    }

    // MARK: Serpent body

    /// Point offset from the centerline by `k` half-widths along the up-normal.
    private func off(_ sp: Spine, _ i: Int, _ k: CGFloat) -> CGPoint {
        let p = sp.points[i], n = sp.normals[i], w = sp.widths[i]
        return CGPoint(x: p.x + n.x * w * k, y: p.y + n.y * w * k)
    }

    private func band(_ sp: Spine, _ range: Range<Int>, from a: CGFloat, to b: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addPolygon(range.map { off(sp, $0, a) } + range.reversed().map { off(sp, $0, b) })
        return path
    }

    private func drawBody(_ ctx: CGContext, _ sp: Spine) {
        let body = 0..<sp.bodyCount
        let s = scale

        ctx.addPath(band(sp, body, from: 1, to: -1))
        ctx.setFillColor(bodyMid)
        ctx.fillPath()

        // Shading: dark underside, lit back
        ctx.addPath(band(sp, body, from: -0.2, to: -1))
        ctx.setFillColor(bodyBottom)
        ctx.fillPath()
        ctx.addPath(band(sp, body, from: 0.9, to: 0.35))
        ctx.setFillColor(rgb(0.30, 0.82, 0.52, 0.45))
        ctx.fillPath()

        // Scale texture: staggered dark dots
        ctx.setFillColor(rgb(0.01, 0.2, 0.12, 0.55))
        for i in stride(from: 3, to: sp.bodyCount - 6, by: 1) {
            let c = off(sp, i, i % 2 == 0 ? 0.55 : 0.1)
            let r = min(0.55 * s, sp.widths[i] * 0.22)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }

        // Golden belly plates
        let bellyRange = 1..<(sp.bodyCount - 8)
        ctx.addPath(band(sp, bellyRange, from: -0.3, to: -0.98))
        ctx.setFillColor(belly)
        ctx.fillPath()
        ctx.setStrokeColor(bellyLine)
        ctx.setLineWidth(0.35 * s)
        for i in stride(from: bellyRange.lowerBound + 1, to: bellyRange.upperBound, by: 1) {
            ctx.move(to: off(sp, i, -0.3))
            ctx.addLine(to: off(sp, i, -0.98))
        }
        ctx.strokePath()
    }

    private func drawFins(_ ctx: CGContext, _ sp: Spine) {
        // Swept-back flame fins along the spine
        ctx.setFillColor(fin)
        let start = 5, end = sp.bodyCount - 4
        for i in stride(from: start, to: end, by: 2) {
            let u = CGFloat(i) / CGFloat(sp.bodyCount)
            let h = (0.9 + 2.0 * (1 - u)) * scale * (1 + 0.18 * sin(time * 9 + CGFloat(i) * 0.7))
            let a = off(sp, i, 0.85), b = off(sp, i + 2, 0.85)
            let n = sp.normals[i + 1], back = sp.back[i + 1]
            let tip = CGPoint(x: b.x + n.x * h + back.x * h * 0.6, y: b.y + n.y * h + back.y * h * 0.6)
            let p = CGMutablePath()
            p.addPolygon([a, tip, b])
            ctx.addPath(p)
        }
        ctx.fillPath()
    }

    private func drawLegs(_ ctx: CGContext, _ sp: Spine, near: Bool) {
        let s = scale
        let positions: [CGFloat] = near ? [0.17, 0.58] : [0.14, 0.55]
        let color = near ? bodyBottom : bodyDark
        for (j, u) in positions.enumerated() {
            let i = Int(u * CGFloat(samples))
            let n = sp.normals[i], back = sp.back[i]
            let fwd = CGPoint(x: -back.x, y: -back.y)
            let phase = sin(time * 5 + CGFloat(j) * 2 + (near ? 0 : 1.4))
            let hip = off(sp, i, -0.4)
            let knee = CGPoint(x: hip.x - n.x * 3.2 * s + back.x * (1.4 + phase) * s,
                               y: hip.y - n.y * 3.2 * s + back.y * (1.4 + phase) * s)
            let foot = CGPoint(x: knee.x - n.x * 1.1 * s + fwd.x * 2.2 * s,
                               y: knee.y - n.y * 1.1 * s + fwd.y * 2.2 * s)
            ctx.setStrokeColor(color)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(1.7 * s)
            ctx.move(to: hip); ctx.addLine(to: knee); ctx.addLine(to: foot)
            ctx.strokePath()

            // Claws
            ctx.setStrokeColor(horn)
            ctx.setLineWidth(0.4 * s)
            for spread in [-0.6, 0.0, 0.6] as [CGFloat] {
                ctx.move(to: foot)
                ctx.addLine(to: CGPoint(x: foot.x + fwd.x * 1.1 * s - n.x * (0.5 + spread) * s,
                                        y: foot.y + fwd.y * 1.1 * s - n.y * (0.5 + spread) * s))
            }
            ctx.strokePath()

            // Little flame tuft at the elbow
            ctx.setFillColor(mane[0])
            let t = CGMutablePath()
            t.addPolygon([knee,
                          CGPoint(x: knee.x + back.x * 2.2 * s - n.x * 0.4 * s, y: knee.y + back.y * 2.2 * s - n.y * 0.4 * s),
                          CGPoint(x: knee.x + n.x * 0.7 * s, y: knee.y + n.y * 0.7 * s)])
            ctx.addPath(t)
            ctx.fillPath()
        }
    }

    private func strand(_ ctx: CGContext, _ pts: [CGPoint], color: CGColor, width: CGFloat) {
        guard pts.count > 1 else { return }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addLines(between: pts)
        ctx.strokePath()
    }

    private func drawMane(_ ctx: CGContext, _ sp: Spine) {
        // Flowing strands from the back of the head down the neck
        let s = scale
        for k in 0..<5 {
            let length = 10 + k * 3
            let lift = 0.7 + CGFloat(k % 3) * 0.35
            var pts: [CGPoint] = []
            for i in 0...length {
                let p = off(sp, i, lift)
                let n = sp.normals[i]
                let prog = CGFloat(i) / CGFloat(length)
                let wave = sin(time * 7 - CGFloat(i) * 0.55 + CGFloat(k) * 1.3) * 1.3 * prog * s
                let rise = (1.2 + CGFloat(k) * 0.35) * sin(prog * .pi) * s
                pts.append(CGPoint(x: p.x + n.x * (wave + rise), y: p.y + n.y * (wave + rise)))
            }
            strand(ctx, pts, color: mane[k % mane.count], width: (1.3 - CGFloat(k) * 0.12) * s)
        }
    }

    private func drawTailTuft(_ ctx: CGContext, _ sp: Spine) {
        let s = scale
        let first = sp.bodyCount - 10
        let last = sp.points.count - 1
        for k in 0..<5 {
            var pts: [CGPoint] = []
            for i in first...last {
                let prog = CGFloat(i - first) / CGFloat(last - first)
                let p = sp.points[i], n = sp.normals[i]
                let spread = (CGFloat(k) - 2) * 1.3 * prog * s
                let wave = sin(time * 6 - CGFloat(i) * 0.5 + CGFloat(k)) * 1.2 * prog * s
                pts.append(CGPoint(x: p.x + n.x * (spread + wave), y: p.y + n.y * (spread + wave)))
            }
            strand(ctx, pts, color: mane[(k + 1) % mane.count], width: (1.2 - abs(CGFloat(k) - 2) * 0.2) * s)
        }
    }

    // MARK: Head (local space: origin at the neck, facing +x, design units)

    private func drawHead(_ ctx: CGContext) {
        // Far antler
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(rgb(0.75, 0.70, 0.58))
        ctx.setLineWidth(0.8)
        ctx.move(to: CGPoint(x: 2.6, y: 2.8))
        ctx.addQuadCurve(to: CGPoint(x: -4.5, y: 8.0), control: CGPoint(x: 0, y: 7))
        ctx.move(to: CGPoint(x: -0.5, y: 6.0)); ctx.addLine(to: CGPoint(x: 0.6, y: 8.6))
        ctx.strokePath()

        // Lower jaw, hinged near the cheek
        let hinge = CGPoint(x: 1.5, y: -2)
        ctx.saveGState()
        ctx.translateBy(x: hinge.x, y: hinge.y)
        ctx.rotate(by: -jaw * 0.5)
        ctx.translateBy(x: -hinge.x, y: -hinge.y)
        let lower = CGMutablePath()
        lower.move(to: CGPoint(x: 0.5, y: -1.4))
        lower.addLine(to: CGPoint(x: 11, y: -2.1))
        lower.addQuadCurve(to: CGPoint(x: 10.2, y: -3.4), control: CGPoint(x: 11.5, y: -3.0))
        lower.addLine(to: CGPoint(x: 1, y: -3.4))
        lower.closeSubpath()
        ctx.addPath(lower)
        ctx.setFillColor(bodyBottom)
        ctx.fillPath()
        // Beard under the chin
        ctx.setFillColor(mane[0])
        let beard = CGMutablePath()
        let sway = sin(time * 6) * 0.6
        beard.addPolygon([CGPoint(x: 8, y: -3.3), CGPoint(x: 2.5 + sway, y: -6.2), CGPoint(x: 4, y: -3.4)])
        ctx.addPath(beard)
        ctx.fillPath()
        if jaw > 0.05 {
            ctx.setFillColor(rgb(0.75, 0.1, 0.08, min(1, jaw * 1.5)))
            ctx.fill(CGRect(x: 2, y: -2.4, width: 8.5, height: 0.6))
        }
        ctx.restoreGState()

        // Skull + upper jaw
        let head = CGMutablePath()
        head.move(to: CGPoint(x: -1.5, y: 1.5))
        head.addQuadCurve(to: CGPoint(x: 4, y: 3.4), control: CGPoint(x: -0.5, y: 3.8))
        head.addLine(to: CGPoint(x: 11, y: 0.8))
        head.addQuadCurve(to: CGPoint(x: 13.6, y: -1.2), control: CGPoint(x: 13.8, y: 0.4))
        head.addLine(to: CGPoint(x: 4, y: -2.2))
        head.addLine(to: CGPoint(x: -0.5, y: -2.6))
        head.closeSubpath()
        ctx.saveGState()
        ctx.addPath(head)
        ctx.clip()
        let colors = [bodyTop, bodyBottom] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 3.5), end: CGPoint(x: 0, y: -2.5), options: [])
        }
        ctx.restoreGState()

        // Snout bulb
        ctx.setFillColor(rgb(0.35, 0.85, 0.55))
        ctx.fillEllipse(in: CGRect(x: 11.3, y: -0.4, width: 1.8, height: 1.4))

        // Teeth
        ctx.setFillColor(horn)
        for x in stride(from: 6.0, through: 12.0, by: 2.0) {
            let t = CGMutablePath()
            t.addPolygon([CGPoint(x: x, y: -1.7), CGPoint(x: x + 0.45, y: -2.7), CGPoint(x: x + 0.9, y: -1.8)])
            ctx.addPath(t)
        }
        ctx.fillPath()

        // Near antler, branched
        ctx.setStrokeColor(horn)
        ctx.setLineWidth(0.9)
        ctx.move(to: CGPoint(x: 1.2, y: 2.6))
        ctx.addQuadCurve(to: CGPoint(x: -6.5, y: 7.2), control: CGPoint(x: -1.5, y: 6.8))
        ctx.move(to: CGPoint(x: -2.0, y: 5.6)); ctx.addLine(to: CGPoint(x: -1.2, y: 8.4))
        ctx.move(to: CGPoint(x: -4.6, y: 6.7)); ctx.addLine(to: CGPoint(x: -4.4, y: 8.6))
        ctx.strokePath()

        // Flame eyebrow
        ctx.setFillColor(mane[1])
        let brow = CGMutablePath()
        brow.addPolygon([CGPoint(x: 6.8, y: 1.9), CGPoint(x: 1.0, y: 4.2 + sin(time * 8) * 0.3), CGPoint(x: 3.6, y: 2.0)])
        ctx.addPath(brow)
        ctx.fillPath()

        // Eye
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 2 * scale, color: rgb(1, 0.8, 0.1, 0.9))
        ctx.setFillColor(rgb(1, 0.86, 0.2))
        ctx.fillEllipse(in: CGRect(x: 4.6, y: 0.3, width: 2, height: 1.4))
        ctx.restoreGState()
        ctx.setFillColor(rgb(0.05, 0.02, 0))
        ctx.fillEllipse(in: CGRect(x: 5.4, y: 0.35, width: 0.5, height: 1.3))
        ctx.fillEllipse(in: CGRect(x: 11.6, y: -0.2, width: 0.7, height: 0.5))   // nostril

        // Long whiskers trailing back from the snout
        for (k, start) in [CGPoint(x: 12.2, y: 0.2), CGPoint(x: 11, y: -1.6)].enumerated() {
            var pts: [CGPoint] = []
            for j in 0...14 {
                let jj = CGFloat(j)
                let lift: CGFloat = k == 0 ? 0.32 : -0.18
                pts.append(CGPoint(x: start.x + 0.6 - jj * 1.6,
                                   y: start.y + jj * lift + sin(time * 4.5 - jj * 0.5 + CGFloat(k) * 2) * jj * 0.16))
            }
            strand(ctx, pts, color: rgb(1, 0.92, 0.7, 0.9), width: 0.45)
        }

        // Smoke puff from the nostril as the jaw opens
        if jaw > 0.1 && jaw < 0.9 {
            ctx.setFillColor(rgb(0.6, 0.6, 0.6, 0.4 * (1 - jaw)))
            ctx.fillEllipse(in: CGRect(x: 13.2, y: 0.0, width: 1.6, height: 1.2))
        }
    }

    // MARK: Snapshot (debugging without a Touch Bar)

    func renderSnapshot(times: [CGFloat], to url: URL, script: (CGFloat) -> Void = { _ in }) {
        let w = Int(bounds.width), h = Int(bounds.height)
        let s = 2
        let gap = 4
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * s, pixelsHigh: (h * s + gap) * times.count,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let gctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = gctx
        let cg = gctx.cgContext
        cg.setFillColor(rgb(0.3, 0.3, 0.3))
        cg.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        var elapsed: CGFloat = 0
        for (i, t) in times.enumerated() {
            while elapsed < t { script(elapsed); step(1.0 / 60.0); elapsed += 1.0 / 60.0 }
            cg.saveGState()
            cg.translateBy(x: 0, y: CGFloat((times.count - 1 - i) * (h * s + gap)))
            cg.scaleBy(x: CGFloat(s), y: CGFloat(s))
            draw(bounds)
            cg.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func debugForceRegen() { beginRebirth() }
    func debugMakeImmuneQuiet() { clockState = .alive; immunityLeft = immunityDuration; torchThisPass = false }
    func debugMakeImmune() { clockState = .alive; clockDamage = 0; immunityLeft = immunityDuration; torchThisPass = true }

    func debugStartLeftward(at x: CGFloat) {
        let s = scale
        head = CGPoint(x: x, y: midY)
        heading = .pi
        headFlip = -1
        direction = -1
        currentSpeed = speed * s
        let length = (bodyLength + tuftLength + 30) * s
        trail = stride(from: x + length, through: x, by: -2 * s).map { CGPoint(x: $0, y: midY) }
    }

    func debugFinger(_ x: CGFloat?) {
        if let x { if !fingerDown { eagerFire = true }; chaseX = x; fingerDown = true } else if fingerDown { fingerDown = false; chaseUntil = time + 1.2 }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
    static let trayID = NSTouchBarItem.Identifier("com.claude.dragonbar.tray")
    static let dragonID = NSTouchBarItem.Identifier("com.claude.dragonbar.dragon")

    let dragonView = DragonView(frame: NSRect(x: 0, y: 0, width: 1085, height: 30))

    lazy var touchBar: NSTouchBar = {
        let tb = NSTouchBar()
        tb.delegate = self
        tb.defaultItemIdentifiers = [Self.dragonID]
        return tb
    }()

    // The system only holds the tray item weakly, so keep it alive here.
    private var trayItem: NSCustomTouchBarItem?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let tray = NSCustomTouchBarItem(identifier: Self.trayID)
        tray.view = NSButton(title: "🐉", target: self, action: #selector(showDragon))
        trayItem = tray
        SystemTouchBar.addSystemTrayItem(tray)
        SystemTouchBar.setControlStripPresence(Self.trayID, true)

        // Menu bar fallback: show / hide / quit
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "🐉"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Dragon", action: #selector(showDragon), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hide Dragon", action: #selector(hideDragon), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DragonBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        status.menu = menu
        statusItem = status

        dragonView.onDoubleTap = { [weak self] in self?.hideDragon() }
        showDragon()

        if let i = CommandLine.arguments.firstIndex(of: "--debug-hide-after"), i + 1 < CommandLine.arguments.count,
           let delay = Double(CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.hideDragon() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemTouchBar.minimize(touchBar)
        SystemTouchBar.setControlStripPresence(Self.trayID, false)
    }

    @objc func showDragon() {
        SystemTouchBar.showsCloseBox(false)
        SystemTouchBar.present(touchBar, trayID: Self.trayID)
    }

    @objc func hideDragon() {
        SystemTouchBar.minimize(touchBar)
        // Re-assert the 🐉 in the Control Strip so there's a way back.
        SystemTouchBar.setControlStripPresence(Self.trayID, true)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.dragonID else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = dragonView
        return item
    }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    let view = DragonView(frame: NSRect(x: 0, y: 0, width: 1085, height: 30))
    view.translatesAutoresizingMaskIntoConstraints = true
    view.frame = NSRect(x: 0, y: 0, width: 1085, height: 30)
    // Dragon heading left toward the clock: burn, shatter, then (much later) regenerate.
    view.debugLog = { FileHandle.standardError.write(($0 + "\n").data(using: .utf8)!) }
    view.debugStartLeftward(at: 230)
    let regenTimes: [CGFloat] = args.firstIndex(of: "--regen-at").flatMap { Double(args[$0 + 1]) }.map { t in
        [CGFloat(t) + 0.3, CGFloat(t) + 0.7, CGFloat(t) + 1.4] } ?? []
    if args.contains("--regen-test") {
        view.renderSnapshot(times: [4.6, 4.8, 5.0, 5.2, 5.4, 5.6, 5.8, 6.0, 6.3, 6.9], to: URL(fileURLWithPath: args[i + 1])) { t in
            if abs(t - 4.4) < 0.01 { view.debugForceRegen() }
        }
        exit(0)
    }
    if args.contains("--sky-test") {
        view.debugMakeImmuneQuiet()
        // (hour, weather) per frame; Oct 2 with DST: sunrise ~7:09, sunset ~18:51
        let scenes: [(CGFloat, DragonView.Weather)] = [(23, .clear), (7.15, .clear), (10, .clear), (13, .cloudy),
                                                       (15, .rain), (18.8, .clear), (21, .rain), (2, .cloudy)]
        let times = scenes.indices.map { CGFloat($0) + 1 }
        view.renderSnapshot(times: times, to: URL(fileURLWithPath: args[i + 1])) { t in
            for (k, scene) in scenes.enumerated() where abs(t - (CGFloat(k) + 0.2)) < 0.008 {
                view.debugSetSky(hour: scene.0, weather: scene.1)
                if k == 6 { view.debugStrike() }
            }
            if abs(t - 6.97) < 0.008 { view.debugStrike() }
        }
        exit(0)
    }
    if let k = args.firstIndex(of: "--hunt-stats"), k + 1 < args.count, let n = Int(args[k + 1]) {
        var results: [String] = []
        for _ in 0..<n {
            let v = DragonView(frame: NSRect(x: 0, y: 0, width: 1085, height: 30))
            v.translatesAutoresizingMaskIntoConstraints = true
            v.frame = NSRect(x: 0, y: 0, width: 1085, height: 30)
            v.debugMakeImmuneQuiet()
            var eatenAt: CGFloat?
            v.debugLog = { msg in if msg.hasPrefix("eaten") { eatenAt = 0 } }
            v.step(1.0 / 60.0)
            v.feed()
            var t: CGFloat = 0
            while eatenAt == nil && t < 120 { v.step(1.0 / 60.0); t += 1.0 / 60.0 }
            results.append(eatenAt == nil ? ">120" : String(format: "%.1f", t))
        }
        print("caught after (s):", results.joined(separator: " "))
        exit(0)
    }
    if args.contains("--feed-test") {
        view.debugMakeImmuneQuiet()
        let times: [CGFloat] = stride(from: 1.0, through: 22.0, by: 1.0).map { CGFloat($0) }
        view.renderSnapshot(times: times, to: URL(fileURLWithPath: args[i + 1])) { t in
            if abs(t - 0.5) < 0.01 { view.feed() }
        }
        exit(0)
    }
    if args.contains("--shield-test") {
        view.debugMakeImmune()
        view.renderSnapshot(times: [1.2, 1.6, 2.0, 2.4, 2.8, 3.4, 4.5], to: URL(fileURLWithPath: args[i + 1]))
        exit(0)
    }
    view.renderSnapshot(times: [0.4, 1.0, 1.6, 2.0, 2.4, 2.8, 3.3, 4.0] + regenTimes, to: URL(fileURLWithPath: args[i + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
