# DragonBar

A long serpent dragon that lives on the MacBook Pro Touch Bar.

It slithers back and forth across a sky that follows your local time and weather, breathes fire, torches the clock, hunts chicks you feed it, and chases your finger.

## Features

- **Serpent dragon.** A 260pt jade dragon with antlers, whiskers, a flowing mane, fins and a tufted tail. Its body follows the path of its head, so it curls through every turn.
- **Fire.** Random fire bursts with embers and glow.
- **Finger chasing.** Touch or drag on the bar and the dragon flies figure-8s through your finger, breathing fire at it. The marker glows and sparks when it's hit.
- **Clock.** The time and date sit on the left. The dragon burns the clock until it shatters into tumbling letters. After 2–4 passes it comes back with a spark, fly-in and shockwave animation, then has a shield for 4 minutes.
- **Feeding.** The 🐔 button on the right (30 s cooldown) releases a chick. The chick dodges, jukes and sweats as the dragon closes in, and the dragon's first snaps miss. After eating, the dragon sends up hearts and does a thank-you figure-8.
- **Sky.** The sky follows the time of day: stars, shooting stars and the moon at night; a warm glow at dawn and dusk; and a sun that crosses the bar during the day. Sunrise and sunset shift with the season.
- **Weather.** It wanders between clear, cloudy and rain. Rain brings splashes and lightning.

## Requirements

- A MacBook Pro with a Touch Bar
- macOS with the Xcode command line tools (`xcode-select --install`)

## Build and run

```bash
./build.sh
open DragonBar.app
```

To install, copy `DragonBar.app` to `/Applications`. To start it at login, add it under System Settings → General → Login Items.

## Controls

| Action | Result |
| --- | --- |
| Touch or drag on the bar | The dragon chases your finger |
| Tap 🐔 | Release a chick |
| Double-tap the bar | Hide the dragon |
| 🐉 in the Control Strip | Show the dragon again |
| 🐉 in the menu bar | Show, hide or quit |

## How it works

The app uses the same private `DFRFoundation` API as Pock and MTMR (`presentSystemModalTouchBar`, `DFRElementSetControlStripPresenceForIdentifier`) to show its view on the Touch Bar system-wide. Everything is drawn with Core Graphics in a single view at 60 fps.

A future macOS release may change these private APIs.

### Debug snapshots

To render frames to a PNG without a Touch Bar:

```bash
./DragonBar.app/Contents/MacOS/DragonBar --snapshot out.png                 # clock burn
./DragonBar.app/Contents/MacOS/DragonBar --snapshot out.png --regen-test    # clock rebirth
./DragonBar.app/Contents/MacOS/DragonBar --snapshot out.png --shield-test   # clock shield
./DragonBar.app/Contents/MacOS/DragonBar --snapshot out.png --feed-test     # chick hunt
./DragonBar.app/Contents/MacOS/DragonBar --snapshot out.png --sky-test      # times of day and weather
./DragonBar.app/Contents/MacOS/DragonBar --snapshot out.png --hunt-stats 30 # how long chicks survive
```

## License

GNU General Public License v2.0. See [LICENSE](LICENSE).
