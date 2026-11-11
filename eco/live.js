// The live Eco Man that can stand anywhere on a page of the app, with no frame (Carlo, Nov 10, 2026, 11:36 p.m.: "build him even if some things don't work on him").
// It is the same model as eco/poke.html. The app loads three.js and then this file only on a page where a live one was placed.
// window.EcoLive.mount(the .eco-spot span, { px: his height, frozen: () => true while the Eco Man bar is open }) gives { destroy, resize, poke }.
(function () {
"use strict";
let cssDone = false;
function css() { if (cssDone) return; cssDone = true; const st = document.createElement("style"); st.textContent = `
.eco-live-box { position: absolute; pointer-events: none; line-height: 1.2; z-index: 3; }
.eco-live-cv { position: absolute; inset: 0; display: block; pointer-events: none; background: none; }
.eco-live-hit { position: absolute; pointer-events: auto; touch-action: none; cursor: grab; -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; background: none; }
.eco-live-hit.holding { cursor: grabbing; }
.eco-live-say { position: absolute; left: 0; top: 0; transform: translate(-50%, -100%); max-width: 260px; width: max-content; background: #fff8e3; color: #1b2c52; border: 3px solid #1b3a6b; border-radius: 8px; padding: 5px 11px; font: 800 clamp(13px, calc(var(--epx, 120px) * .14), 22px)/1.2 system-ui, "Segoe UI", Arial, sans-serif; text-align: center; white-space: normal; pointer-events: none; opacity: 0; transition: opacity .15s; box-shadow: 0 4px 12px rgba(27, 58, 107, .2); }
.eco-live-say.on { opacity: 1; }
.eco-spot.live-on > img.eco-man { opacity: 0 !important; pointer-events: none !important; }
body.eco-find .eco-spot.live-on > img.eco-man, body.eco-placing .eco-spot.live-on > img.eco-man { opacity: 1 !important; pointer-events: auto !important; }
body.eco-find .eco-live-box, body.eco-placing .eco-live-box { display: none; }
@media print { .eco-live-box { display: none !important; } }`; document.head.appendChild(st); }
function mount(sp, opt) {
  opt = opt || {}; if (!window.THREE || !sp) return null; css();
  let PX = Math.max(40, Math.min(400, +opt.px || 120)), dead = false, vis = true; const frozen = opt.frozen || (() => false);
  const stage = document.createElement("div"); stage.className = "eco-live-box"; const cv = document.createElement("canvas"); cv.className = "eco-live-cv"; cv.setAttribute("aria-hidden", "true");
  const sayEl = document.createElement("div"); sayEl.className = "eco-live-say"; sayEl.setAttribute("role", "status"); const hitEl = document.createElement("div"); hitEl.className = "eco-live-hit"; hitEl.title = "Eco Man. Poke him or push him.";
  stage.append(cv, hitEl, sayEl); sp.appendChild(stage);
  const T = THREE, V = (x, y, z = 0) => new T.Vector3(x, y, z), PI = Math.PI, sin = Math.sin, cos = Math.cos, abs = Math.abs;
  const clamp = (v, a, b) => Math.min(b, Math.max(a, v)), lerp = (a, b, u) => a + (b - a) * u, rnd = a => a[Math.floor(Math.random() * a.length)];
  let renderer;
  try { renderer = new T.WebGLRenderer({ canvas: cv, antialias: true, alpha: true }); }
  catch (e) { stage.remove(); return null; }
  renderer.setClearColor(0, 0); renderer.toneMapping = T.ACESFilmicToneMapping; renderer.shadowMap.enabled = true; renderer.shadowMap.type = T.PCFSoftShadowMap;
  const scene = new T.Scene(), cam = new T.PerspectiveCamera(20, 1.39, 0.1, 200);
  // a small made-up room so the shiny paint has something to reflect
  (function () { const es = new T.Scene(); es.add(new T.Mesh(new T.SphereGeometry(40, 24, 16), new T.MeshBasicMaterial({ color: 0x9fb2d0, side: T.BackSide })));
    [[0, 30, 0, 30], [-25, 10, 20, 14], [25, 8, 14, 10]].forEach(p => { const m = new T.Mesh(new T.SphereGeometry(p[3], 16, 12), new T.MeshBasicMaterial({ color: 0xffffff })); m.position.set(p[0], p[1], p[2]); es.add(m); });
    scene.environment = new T.PMREMGenerator(renderer).fromScene(es, 0.05).texture; })();
  const key = new T.DirectionalLight(0xffffff, 2.6); key.position.set(-5, 13, 9); key.castShadow = true;
  Object.assign(key.shadow.camera, { left: -9, right: 9, top: 12, bottom: -3, near: 1, far: 40 }); key.shadow.mapSize.set(1024, 1024); key.shadow.radius = 6; key.shadow.bias = -0.0005; key.shadow.normalBias = 0.03;
  scene.add(key, new T.HemisphereLight(0xffffff, 0x9fb0d0, 0.55));
  const rim = new T.DirectionalLight(0xcfe0ff, 1.0); rim.position.set(7, 6, -6); scene.add(rim);
  const ground = new T.Mesh(new T.PlaneGeometry(80, 80), new T.ShadowMaterial({ opacity: 0.22, color: 0x0c1c40 })); ground.rotation.x = -PI / 2; ground.receiveShadow = true; scene.add(ground);

  const mk = (c, o = {}) => new T.MeshPhysicalMaterial({ color: c, roughness: 0.42, clearcoat: 0.5, clearcoatRoughness: 0.3, envMapIntensity: 0.55, ...o });
  const M = { white: mk(0xf3f5fa), navy: mk(0x17336b), blue: mk(0x2a6cc6), red: mk(0xc0101f, { clearcoat: 0, roughness: 0.55 }), dred: mk(0x8f0f1d, { clearcoat: 0.1 }), lid: mk(0xc6d4ec),
    mouth: mk(0x0f2046, { roughness: 0.7, clearcoat: 0 }), pink: mk(0xe8596b), pane: mk(0xffffff, { roughness: 0.15, clearcoat: 1 }), iris: mk(0x2f78dc, { roughness: 0.15, clearcoat: 1 }), pupil: mk(0x0d1f45, { roughness: 0.1, clearcoat: 1 }), hi: new T.MeshBasicMaterial({ color: 0xffffff }) };
  function add(p, geo, m, pos, o = {}) { const me = new T.Mesh(geo, m); me.castShadow = !o.noShadow; me.receiveShadow = true; if (pos) me.position.copy(pos); if (o.s) me.scale.set(...o.s); if (o.r) me.rotation.set(...o.r); if (o.part) me.userData.part = o.part; p.add(me); return me; }
  const sph = r => new T.SphereGeometry(r, 32, 22);
  function rbox(w, h, d, r) { const b = Math.min(r, w / 2 - .001, h / 2 - .001, d / 2 - .001), x = w / 2 - b, y = h / 2 - b, s = new T.Shape(); s.moveTo(-x, -y); s.lineTo(x, -y); s.lineTo(x, y); s.lineTo(-x, y); s.closePath();
    const g = new T.ExtrudeGeometry(s, { depth: d - 2 * b, bevelEnabled: true, bevelThickness: b, bevelSize: b, bevelSegments: 3 }); g.translate(0, 0, -(d - 2 * b) / 2); return g; }
  function ext(p, shape, depth, m, z, bev, part) { return add(p, new T.ExtrudeGeometry(shape, { depth, bevelEnabled: bev > 0, bevelThickness: bev, bevelSize: bev, bevelSegments: 3, curveSegments: 24 }), m, V(0, 0, z), { part }); }
  function tube(p, curve, r, m, z, part) { add(p, new T.TubeGeometry(curve, 40, r, 12, false), m, V(0, 0, z), { part }); add(p, sph(r), m, curve.getPoint(0).add(V(0, 0, z)), { part }); add(p, sph(r), m, curve.getPoint(1).add(V(0, 0, z)), { part }); }
  const quad = (a, b, c) => new T.QuadraticBezierCurve3(a, b, c);

  // ---- the rig: root (slide, turn) > tip (lean, squash; pivot on the ground) > U (the house)
  const root = new T.Group(), tip = new T.Group(), flip = new T.Group(), U = new T.Group(); scene.add(root); root.add(tip); tip.add(flip); flip.add(U);
  flip.position.y = 2.85; U.position.y = 0.25 - 2.85;   // flip turns him about his middle
  const hs = new T.Shape(); hs.moveTo(-1.4, .6); hs.lineTo(1.4, .6); hs.lineTo(1.4, 3.45); hs.lineTo(0, 4.8); hs.lineTo(-1.4, 3.45); hs.closePath();
  ext(U, hs, 2.0, M.white, -1.0, .1, "body");
  add(U, rbox(3.08, .22, 2.28, .08), M.blue, V(0, .6, 0), { part: "body" });
  const ra = Math.atan2(1.45, 1.5);
  for (const s of [-1, 1]) { add(U, rbox(3.0, .3, 2.75, .1), M.red, V(s * cos(ra) * 1.38, 5.12 - sin(ra) * 1.38, 0), { r: [0, 0, -s * ra], part: "roof" }); add(U, rbox(.42, .34, 2.79, .1), M.dred, V(s * cos(ra) * 2.72, 5.12 - sin(ra) * 2.72, 0), { r: [0, 0, -s * ra], part: "roof" }); }
  add(U, new T.CapsuleGeometry(.2, 2.4, 8, 20), M.dred, V(0, 5.16, 0), { r: [PI / 2, 0, 0], part: "roof" });
  add(U, rbox(.52, 1.3, .52, .05), M.red, V(.98, 4.65, -.2), { part: "chimney" }); add(U, rbox(.7, .2, .7, .07), M.dred, V(.98, 5.36, -.2), { part: "chimney" });
  // back window
  add(U, rbox(.9, .9, .16, .07), M.navy, V(0, 2.85, -1.1), { part: "body" }); for (const [bx, by] of [[-.2, .2], [.2, .2], [-.2, -.2], [.2, -.2]]) add(U, rbox(.33, .33, .16, .04), M.pane, V(bx, 2.85 + by, -1.115), { part: "body" });
  // eyes
  const eyes = [-1, 1].map(s => { const cx = s * .72, cy = 2.95, e = { s, cx };
    add(U, rbox(.8, .76, .16, .07), M.navy, V(cx, cy, 1.1), { part: "eye" + s }); add(U, rbox(.62, .58, .16, .05), M.pane, V(cx, cy, 1.115), { part: "eye" + s });
    e.ball = new T.Group(); e.ball.position.set(cx, cy, 1.19); U.add(e.ball);
    add(e.ball, sph(.175), M.iris, V(0, 0, 0), { s: [1, 1, .3], part: "eye" + s }); add(e.ball, sph(.085), M.pupil, V(0, 0, .035), { s: [1, 1, .3] }); add(e.ball, sph(.042), M.hi, V(.055, .065, .06), { s: [1, 1, .4], noShadow: true });
    add(U, rbox(.96, .11, .3, .05), M.navy, V(cx, cy - .43, 1.17), { part: "eye" + s });
    const lg = new T.BoxGeometry(.62, .58, .1); lg.translate(0, -.29, 0); e.lid = add(U, lg, M.lid, V(cx, 3.24, 1.23), { part: "eye" + s });
    const eg = new T.BoxGeometry(.64, .05, .12); e.edge = add(U, eg, M.navy, V(cx, 3.24, 1.23));
    e.brow = add(U, new T.CapsuleGeometry(.062, .62, 6, 14), M.navy, V(cx, 3.62, 1.2), { part: "eye" + s }); return e; });
  // door nose
  add(U, rbox(.52, .94, .2, .07), M.navy, V(0, 2.42, 1.1), { part: "nose" }); add(U, rbox(.38, .8, .22, .05), M.white, V(0, 2.42, 1.14), { part: "nose" }); add(U, sph(.05), M.navy, V(.11, 2.38, 1.26), { part: "nose" });
  // mouths (one shows at a time)
  const mouths = {}; const mg = n => { const g = new T.Group(); g.position.y = .17; U.add(g); mouths[n] = g; return g; };
  (function () { const G = mg("happy"), pv = new T.Group(); pv.position.y = 1.55; G.add(pv); const I = new T.Group(); I.position.y = -1.55; pv.add(I); G.userData.pv = pv;
    const m = new T.Shape(); m.moveTo(-.95, 1.55); m.quadraticCurveTo(0, 1.4, .95, 1.55); m.quadraticCurveTo(.79, .7, 0, .68); m.quadraticCurveTo(-.79, .7, -.95, 1.55); ext(I, m, .05, M.mouth, 1.08, 0, "mouth");
    tube(I, quad(V(-.95, 1.55), V(0, 1.4), V(.95, 1.55)), .045, M.navy, 1.12, "mouth");
    const te = new T.Shape(); te.moveTo(-.9, 1.54); te.quadraticCurveTo(0, 1.4, .9, 1.54); te.lineTo(.84, 1.36); te.quadraticCurveTo(0, 1.22, -.84, 1.36); te.closePath(); ext(I, te, .06, M.pane, 1.1, .015, "mouth");
    const to = new T.Shape(); to.absellipse(0, .9, .34, .18, 0, 2 * PI); ext(I, to, .05, M.pink, 1.1, .015, "mouth"); })();
  tube(mg("sad"), quad(V(-.75, 1.06), V(0, 1.6), V(.75, 1.06)), .065, M.blue, 1.12, "mouth");
  tube(mg("wavy"), new T.CatmullRomCurve3([V(-.7, 1.27), V(-.48, 1.42), V(-.26, 1.3), V(-.04, 1.2), V(.18, 1.3), V(.4, 1.42), V(.65, 1.38)]), .065, M.blue, 1.12, "mouth");
  (function () { const G = mg("angry"), c = quad(V(-.79, .99), V(0, 1.6), V(.79, .99)); tube(G, c, .15, M.navy, 1.08, "mouth"); tube(G, c, .1, M.pane, 1.16, "mouth");
    for (const u of [.25, .5, .75]) { const q = c.getPoint(u), tg = c.getTangent(u); add(G, rbox(.035, .2, .06, .012), M.navy, V(q.x, q.y, 1.25), { r: [0, 0, Math.atan2(tg.y, tg.x)] }); } })();
  (function () { const G = mg("oh"), o = new T.Shape(); o.absellipse(0, 1.2, .3, .38, 0, 2 * PI); ext(G, o, .05, M.mouth, 1.08, 0, "mouth"); add(G, new T.TorusGeometry(.34, .05, 10, 32), M.navy, V(0, 1.2, 1.13), { s: [.9, 1.13, 1], part: "mouth" }); })();
  // arms
  const UP = V(0, 1, 0), S0 = V(1.5, 2.1, .3);
  const POSE = { rest: [V(2.0, 1.4, .45), V(2.1, .85, .6)], hip: [V(2.75, 1.6, 0), V(1.9, 1.15, .65)], flex: [V(2.85, 1.95, .3), V(2.8, 3.3, .45)], up: [V(2.3, 2.85, .5), V(2.5, 3.95, .6)], out: [V(2.6, 2.1, .5), V(3.5, 2.3, .7)], shrug: [V(2.4, 1.5, .5), V(3.15, 2.05, .8)], guard: [V(2.3, 2.3, .9), V(1.5, 3.1, 1.5)] };
  const arms = [1, -1].map(side => { const g = new T.Group(); g.scale.x = side; U.add(g); const a = { side, g, E: POSE.rest[0].clone(), H: POSE.rest[1].clone() };
    add(g, sph(.34), M.white, S0.clone().add(V(.06, 0, 0)), { part: "arm" });
    a.up = add(g, new T.CylinderGeometry(.26, .26, 1, 20), M.white, null, { part: "arm" }); a.el = add(g, sph(.27), M.white, null, { part: "arm" }); a.fo = add(g, new T.CylinderGeometry(.235, .235, 1, 20), M.white, null, { part: "arm" });
    a.bi = add(g, sph(.42), M.white, null, { s: [1.2, .9, .95], part: "arm" });
    a.hand = new T.Group(); g.add(a.hand); add(a.hand, sph(.4), M.white, V(0, 0, 0), { s: [1, .96, .92], part: "fist" });
    for (let i = 0; i < 4; i++) add(a.hand, sph(.135), M.white, V((i - 1.5) * .17, .2, .2), { part: "fist" }); add(a.hand, sph(.16), M.white, V(.12, -.08, .33), { s: [1.25, .85, .8], part: "fist" }); return a; });
  function limb(c, a, b) { c.position.copy(a).add(b).multiplyScalar(.5); c.scale.set(1, a.distanceTo(b), 1); c.quaternion.setFromUnitVectors(UP, b.clone().sub(a).normalize()); }
  // shoes
  const feet = [-1, 1].map(s => { const g = new T.Group(); g.position.set(s * .74, 0, -.1); g.rotation.y = s * .12; root.add(g);
    add(g, sph(1), M.blue, V(0, .15, .8), { s: [.6, .15, .97], part: "foot" }); add(g, new T.SphereGeometry(1, 32, 16, 0, 2 * PI, 0, PI / 2), M.white, V(0, .22, .8), { s: [.54, .66, .9], part: "foot" }); add(g, new T.SphereGeometry(1, 32, 16, 0, 2 * PI, 0, PI / 2), M.white, V(0, .22, .3), { s: [.44, .72, .42], part: "foot" }); return { g, s }; });
  // little extras: stars for dizzy, puffs for the chimney
  const fx = new T.Group(); scene.add(fx);
  const starShape = (() => { const sh = new T.Shape(); for (let i = 0; i < 8; i++) { const a = i * PI / 4, r = i % 2 ? .25 : 1; i ? sh.lineTo(sin(a) * r, cos(a) * r) : sh.moveTo(sin(a) * r, cos(a) * r); } sh.closePath(); return new T.ShapeGeometry(sh); })();
  const stars = [0, 1, 2, 3, 4].map(() => { const m = new T.Mesh(starShape, new T.MeshBasicMaterial({ color: 0xffd84a, side: T.DoubleSide, toneMapped: false })); m.visible = false; fx.add(m); return m; });
  const puffs = []; const puffGeo = sph(1);
  function puff(p, n = 4) { for (let i = 0; i < n; i++) { const m = new T.Mesh(puffGeo, new T.MeshStandardMaterial({ color: 0xd3dbe8, transparent: true, opacity: .9, roughness: 1 })); m.position.copy(p).add(V((Math.random() - .5) * .3, i * .25, 0)); m.userData = { t: -i * .08, v: V((Math.random() - .5) * .6, 1.6 + Math.random() * .6, 0) }; m.scale.setScalar(.14); fx.add(m); puffs.push(m); } }

  // ---- looks
  const LOOK = { happy: { by: 3.62, tilt: 0, lid: 0, m: "happy", open: 1 }, giggle: { by: 3.66, tilt: -.12, lid: .5, m: "happy", open: 1.12 }, wow: { by: 3.88, tilt: 0, lid: 0, m: "oh" }, sad: { by: 3.6, tilt: -.32, lid: .3, m: "sad" },
    angry: { by: 3.47, tilt: .36, lid: .38, m: "angry", lidTilt: .2 }, dizzy: { by: 3.7, tilt: -.15, lid: .22, m: "wavy" }, sleepy: { by: 3.55, tilt: 0, lid: .62, m: "wavy" } };
  const S = { x: 0, vx: 0, th: 0, om: 0, yaw: 0, wy: 0, y: 0, vy: 0, sq: 0, vs: 0, ph: 0, flipT: 0, flipDur: 0, flipDir: 0, mode: "up", modeT: 0, fallDir: 1, look: "happy", lookT: 0, pose: "rest", poseT: 0, blink: 0, nextBlink: 2, lookX: 0, lookY: 0, eyeShut: [0, 0],
    idle: 0, spun: 0, dizzy: 0, pokes: [], nPokes: 0, nFalls: 0, t: 0, lidNow: 0, tiltNow: 0, byNow: 3.62, open: 1, sayT: 0, last: "", tap: 0 };
  function setLook(n, secs) { S.look = n; S.lookT = secs || 0; }
  function setPose(n, secs) { S.pose = n; S.poseT = secs || 0; }
  function say(lines, secs) { let l = Array.isArray(lines) ? rnd(lines) : lines; if (Array.isArray(lines) && lines.length > 1) while (l === S.last) l = rnd(lines); S.last = l; sayEl.textContent = l; sayEl.classList.add("on"); S.sayT = secs || 2.2; }
  function did() { }
  function tally() { }
  function jump(v, flipDir) { if (S.y > 0.01 || S.mode !== "up") return; S.vy = v; setPose("up", 1.2); if (flipDir) { S.flipDir = flipDir; S.flipT = 0; S.flipDur = 2 * v / 24; } }

  const REACT = {
    body: () => { S.vs += 3.2; setLook("giggle", 1.4); say(["Hee hee! That tickles!", "Ha ha! Stop it!", "Boop!", "Right in the siding!"]); },
    roof: () => { S.vs += 5; setLook("wow", 1.2); setPose("guard", 1.2); say(["Hey! Watch the roof!", "Bonk!", "Those shingles are new!"]); },
    chimney: () => { const p = new T.Vector3(); U.localToWorld(p.set(.98, 5.5, -.2)); puff(p, 5); setLook("wow", 1); say(["Achoo!", "Puff puff!", "You cleaned my chimney!"]); },
    eye: s => { S.eyeShut[s < 0 ? 0 : 1] = 1.1; setLook("sad", 1.3); setPose("guard", 1.1); say(["Ow! My eye!", "I need that to see!", "Not the window!"]); },
    nose: () => { jump(5); setLook("giggle", 1.2); say(["Ding dong!", "Nobody is home!", "Honk!", "Knock knock!"]); },
    mouth: () => { S.chomp = .5; setLook("happy", 1); say(["Nom nom nom!", "Mmm, fingers.", "Chomp!"]); },
    arm: () => { setPose("flex", 1.8); setLook("happy", 1.8); say(["Feel that muscle!", "Strong like a house!", "Solid as brick!"]); },
    fist: () => { setPose("flex", 1.8); setLook("giggle", 1.4); say(["Fist bump!", "Pow!", "Feel that muscle!"]); },
    foot: () => { jump(6.5); setLook("wow", .9); say(["Hop!", "Careful, new shoes!", "That tickles my toes!"]); }
  };
  function poke(part) { S.nPokes++; tally(); did("poke"); S.idle = 0; const now = S.t; S.pokes.push(now); S.pokes = S.pokes.filter(t => now - t < 4);
    if (S.mode === "down") { say(["Let me get up first!", "Give me a second…"]); return; }
    if (S.pokes.length >= 11) { S.pokes = []; did("angry"); setLook("giggle", 2); say("You can not catch me!", 2.4); jump(12, -1); return; }
    if (S.pokes.length >= 6) { did("angry"); setLook("angry", 2.4); setPose("hip", 2.4); S.om += (Math.random() - .5) * 3; say(["Stop poking me!", "Enough already!", "I am a house, not a doorbell!"], 2.4); return; }
    if (/^eye/.test(part)) REACT.eye(part === "eye-1" ? -1 : 1); else (REACT[part] || REACT.body)(); }

  // ---- pointer
  const ray = new T.Raycaster(), ndc = new T.Vector2(), tmpV = new T.Vector3(); let drag = null, wpp = .02;
  function at(ev) { const r = cv.getBoundingClientRect(); ndc.set((ev.clientX - r.left) / r.width * 2 - 1, -((ev.clientY - r.top) / r.height) * 2 + 1); return r; }
  function hit(ev) { at(ev); ray.setFromCamera(ndc, cam); const hs = ray.intersectObject(root, true); for (const h of hs) { let o = h.object; while (o && !o.userData.part) o = o.parent; if (o) return { part: o.userData.part, point: h.point }; } return null; }
  hitEl.addEventListener("pointerdown", ev => { if (frozen()) return; const h = hit(ev); S.idle = 0; if (!h) return; ev.preventDefault(); ev.stopPropagation(); try { hitEl.setPointerCapture(ev.pointerId); } catch (e) { }
    drag = { part: h.part, x0: ev.clientX, y0: ev.clientY, x: ev.clientX, y: ev.clientY, t0: ev.timeStamp, t: ev.timeStamp, vx: 0, vy: 0, gh: clamp(h.point.y, .3, 5.6), sx: S.x, moved: false, low: h.point.y < 1.1 || h.part === "foot" }; hitEl.classList.add("holding"); });
  const onLook = ev => { if (dead) return; at(ev); S.lookX = clamp(ndc.x * .8, -1, 1); S.lookY = clamp((ndc.y + .2) * .8, -1, 1); }; document.addEventListener("pointermove", onLook, { passive: true });
  hitEl.addEventListener("pointermove", ev => { at(ev);
    if (!drag) return; const now = ev.timeStamp, dt = Math.max(4, now - drag.t) / 1000; drag.vx = lerp(drag.vx, (ev.clientX - drag.x) / dt, .6); drag.vy = lerp(drag.vy, (ev.clientY - drag.y) / dt, .6); drag.x = ev.clientX; drag.y = ev.clientY; drag.t = now;
    if (Math.hypot(drag.x - drag.x0, drag.y - drag.y0) > 9) drag.moved = true; S.idle = 0; });
  function drop(ev) { if (!drag) return; const d = drag; drag = null; hitEl.classList.remove("holding"); const tn = ev && ev.timeStamp ? ev.timeStamp : d.t + 999, quick = tn - d.t0 < 380, stale = tn - d.t > 140;
    if (!d.moved && quick) { poke(d.part); return; } if (!d.moved) { poke(d.part); return; }
    const vx = stale ? 0 : d.vx, vy = stale ? 0 : d.vy;
    if (S.mode !== "up") return;
    if (S.sq > .14) { did("squash"); const p = S.sq; S.vs = -6; jump(5 + p * 22); setLook("wow", 1); say(["Boing!", "Sproing!", "Whee!"]); return; }
    if (vy < -850 && abs(vy) > abs(vx)) { S.th *= .3; S.om *= .3; did("jump"); const f = vy < -1700; jump(f ? 12.5 : 10, f ? (Math.random() < .5 ? 1 : -1) : 0); setLook(f ? "wow" : "giggle", 1.6); say(f ? ["Wheee! A flip!", "Look at me go!"] : ["Whee!", "Up we go!", "Higher!"]); return; }
    if (abs(vx) > 1200 && abs(vx) > abs(vy) && quick) { did("spin"); S.th *= .3; S.om = 0; S.wy = Math.sign(vx) * clamp(abs(vx) / 110, 10, 26); S.spun = 0; setLook("wow", 1.2); setPose("out", 2); say(["Whoa whoa whoa!", "Round and round!", "I am a spinning top!"]); return; }
    if (abs(S.th) > .12) { did("lean"); say(["Whoa! Wobbly!", "Easy now!", "I bend, I do not break!"], 1.6); setLook("wow", 1); } }
  hitEl.addEventListener("pointerup", drop); hitEl.addEventListener("pointercancel", drop); hitEl.addEventListener("lostpointercapture", () => { if (drag) drop(); }); hitEl.addEventListener("click", ev => ev.stopPropagation()); hitEl.addEventListener("dragstart", ev => ev.preventDefault());
  // ---- size
  // the drawing area is bigger than he is, so he has room to lean, fall and jump; only the small box on him takes clicks
  const VH = 12.9, GROUND = 2.3;
  function size() { const w = Math.round(PX * 3.2), h = Math.round(PX * 2.3); stage.style.width = w + "px"; stage.style.height = h + "px"; stage.style.left = "calc(50% - " + (w / 2) + "px)"; stage.style.top = "calc(50% - " + Math.round(h * .605) + "px)"; stage.style.setProperty("--epx", PX + "px");
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2)); renderer.setSize(w, h, false); cv.style.width = w + "px"; cv.style.height = h + "px";
    cam.aspect = w / h; const z = (VH / 2) / Math.tan(10 * PI / 180); cam.position.set(0, VH / 2 - GROUND, z); cam.lookAt(0, VH / 2 - GROUND, 0); cam.updateProjectionMatrix(); wpp = VH / h; }
  size(); let io = null; try { io = new IntersectionObserver(es => { vis = es[es.length - 1].isIntersecting; }); io.observe(stage); } catch (e) { }
  function destroy() { if (dead) return; dead = true; document.removeEventListener("pointermove", onLook); try { io && io.disconnect(); } catch (e) { }
    scene.traverse(o => { if (o.geometry) o.geometry.dispose(); }); try { scene.environment && scene.environment.dispose(); renderer.dispose(); renderer.forceContextLoss(); } catch (e) { } stage.remove(); }
  const hb = [V(-1.9, 0, 0), V(1.9, 0, 0), V(-2.1, 5.7, 0), V(2.1, 5.7, 0), V(-3.2, 2.4, 0), V(3.2, 2.4, 0)];
  function hitBox() { let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9; const w = stage.clientWidth, h = stage.clientHeight;
    for (const p of hb) { tip.localToWorld(tmpV.copy(p)); tmpV.project(cam); const x = (tmpV.x + 1) / 2 * w, y = (1 - tmpV.y) / 2 * h; x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
    x0 = clamp(x0, 0, w); x1 = clamp(x1, 0, w); y0 = clamp(y0, 0, h); y1 = clamp(y1, 0, h); hitEl.style.left = x0 + "px"; hitEl.style.top = y0 + "px"; hitEl.style.width = Math.max(10, x1 - x0) + "px"; hitEl.style.height = Math.max(10, y1 - y0) + "px"; }

  // ---- every frame
  let prev = performance.now(), shown = false;
  function frame(now) { if (dead) return; if (!sp.isConnected) { destroy(); return; }
    if (document.hidden || !vis || frozen()) { prev = now; if (drag) { drag = null; hitEl.classList.remove("holding"); } requestAnimationFrame(frame); return; }
    const dt = Math.min(.033, (now - prev) / 1000); prev = now; S.t += dt; S.idle += dt;
    // timers
    if (S.lookT > 0 && (S.lookT -= dt) <= 0) S.look = S.dizzy > 0 ? "dizzy" : "happy"; if (S.poseT > 0 && (S.poseT -= dt) <= 0) S.pose = "rest";
    if (S.sayT > 0 && (S.sayT -= dt) <= 0) sayEl.classList.remove("on"); if (S.dizzy > 0 && (S.dizzy -= dt) <= 0 && S.look === "dizzy") S.look = "happy";
    // holding him
    let sqT = 0;
    if (drag && drag.moved && S.mode === "up" && S.y < .01) { const dx = (drag.x - drag.x0) * wpp, dy = (drag.y - drag.y0) * wpp;
      if (drag.low) { const tx = clamp(drag.sx + dx, -2.6, 2.6); S.vx = (tx - S.x) / Math.max(dt, .008) * .5; S.x = lerp(S.x, tx, .5); S.om += -S.vx * .6 * dt; if (abs(dx) > .6) did("slide"); }
      else { const tt = clamp(-dx / (drag.gh * .62), -1.4, 1.4); S.om += (tt - S.th) * 150 * dt; S.om *= Math.exp(-14 * dt); if (dy > .25 && abs(dx) < dy) sqT = clamp((dy - .25) * .13, 0, .4); } }
    // lean
    const held = drag && drag.moved && !drag.low && S.y < .01;
    if (S.mode === "up") { S.om += ((held ? 0 : -72 * S.th) - 5.5 * S.om) * dt; S.th += S.om * dt;
      const flicking = drag && (drag.t - drag.t0) < 260; if (flicking) S.th = clamp(S.th, -.9, .9);
      if (abs(S.th) > 1.0 && !flicking) { S.mode = "fall"; S.fallDir = Math.sign(S.th); S.om = S.fallDir * 2.5; drag = null; hitEl.classList.remove("holding"); setLook("wow", 5); setPose("out", 5); say(["Whoooa!", "Timber!", "Going dowwwn!"], 1.2); } }
    else if (S.mode === "fall") { S.om += S.fallDir * 16 * dt; S.th += S.om * dt; if (abs(S.th) >= PI / 2) { S.th = S.fallDir * PI / 2; S.om = 0; S.mode = "down"; S.modeT = 0; S.vs = 4; S.nFalls++; tally(); did("fall"); did("lean"); S.dizzy = 2.6; setLook("dizzy", 2.6); setPose("shrug", 2.6); say(["Oof!", "Ouch. That was my good side.", "Who moved the floor?"], 2.2); } }
    else if (S.mode === "down") { S.modeT += dt; if (S.modeT > 2.6) { S.mode = "rise"; S.modeT = 0; } }
    else if (S.mode === "rise") { S.modeT += dt; const u = clamp(S.modeT / .8, 0, 1), e = u * u * (3 - 2 * u); S.th = S.fallDir * PI / 2 * (1 - e); if (u >= 1) { S.mode = "up"; S.th = 0; S.om = -S.fallDir * 2.2; setLook("happy"); setPose("flex", 1.6); say(["I am okay!", "Houses always get back up!", "Do not push so hard!"], 2.2); } }
    // slide home
    if (!(drag && drag.low && drag.moved)) { S.vx += (-5 * S.x - 3.6 * S.vx) * dt; S.x += S.vx * dt; }
    // spin
    if (abs(S.wy) > .01 || abs(S.yaw) > .001) { S.yaw += S.wy * dt; S.spun += abs(S.wy) * dt; S.wy *= Math.exp(-1.15 * dt);
      if (abs(S.wy) < 2.2) { const home = Math.round(S.yaw / (2 * PI)) * 2 * PI; S.wy += ((home - S.yaw) * 30 - 6 * S.wy) * dt; if (abs(home - S.yaw) < .01 && abs(S.wy) < .05) { S.yaw = 0; S.wy = 0; if (S.spun > 11) { S.dizzy = 3; setLook("dizzy", 3); setPose("shrug", 3); S.om += 3; say(["I am so dizzy…", "The room is spinning!", "Which way is the front door?"], 2.6); } S.spun = 0; } } }
    // jump and flip
    if (S.y > 0 || S.vy > 0) { S.vy -= 24 * dt; S.y += S.vy * dt; if (S.flipDur > 0) S.flipT += dt; if (S.y <= 0) { S.y = 0; const v = -S.vy; S.vy = 0; S.vs = Math.min(9, v * .7); S.flipDur = 0; S.flipT = 0; } }
    // squash
    if (sqT > 0) { S.sq = lerp(S.sq, sqT, .35); S.vs = 0; } else { S.vs += (-230 * S.sq - 13 * S.vs) * dt; S.sq = clamp(S.sq + S.vs * dt, -.25, .45); }
    // idle
    S.tap = 0; if (S.idle > 40 && S.mode === "up") { if (S.idle < 40.1) setPose("hip", 5); S.tap = Math.max(0, sin(S.t * 9)); if (S.idle > 45) S.idle = 0; }
    // apply to the rig
    root.position.x = S.x; root.rotation.y = S.yaw; tip.rotation.z = S.th; tip.position.y = S.y + 1.45 * abs(sin(S.th)); tip.position.x = 0;
    const br = S.mode === "up" ? .012 * sin(S.t * 2.2) : 0; tip.scale.set(1 + S.sq * .5, 1 - S.sq + br, 1 + S.sq * .5);
    flip.rotation.x = S.flipDur > 0 ? S.flipDir * 2 * PI * clamp(S.flipT / S.flipDur, 0, 1) : 0;
    // face
    const L = LOOK[S.look] || LOOK.happy; if ((S.nextBlink -= dt) <= 0) { S.blink = .14; S.nextBlink = 1.8 + Math.random() * 3.5; } if (S.blink > 0) S.blink -= dt;
    S.byNow = lerp(S.byNow, L.by, .25); S.tiltNow = lerp(S.tiltNow, L.tilt, .25); S.lidNow = lerp(S.lidNow, L.lid, .3); S.open = lerp(S.open, L.open || 1, .3);
    for (const n in mouths) mouths[n].visible = n === L.m; if (S.chomp > 0) S.chomp -= dt; const ch = S.chomp > 0 ? .55 + .45 * cos(S.chomp * 26) : 1; mouths.happy.userData.pv.scale.y = S.open * ch;
    eyes.forEach((e, i) => { if (S.eyeShut[i] > 0) S.eyeShut[i] -= dt; const shut = S.blink > 0 || S.eyeShut[i] > 0 ? 1 : S.lidNow, lt = (L.lidTilt || 0) * -e.s;
      e.lid.scale.y = Math.max(.001, shut); e.lid.rotation.z = lt; e.lid.visible = shut > .02; e.edge.visible = shut > .02; e.edge.position.set(e.cx, 3.24 - .58 * shut, 1.23); e.edge.rotation.z = lt;
      e.brow.position.y = S.byNow + (S.eyeShut[i] > 0 ? -.08 : 0); e.brow.rotation.z = PI / 2 + S.tiltNow * e.s;
      let lx = S.lookX, ly = S.lookY; if (S.dizzy > 0) { lx = cos(S.t * 9 + i); ly = sin(S.t * 9 + i); } e.ball.position.x = lerp(e.ball.position.x, e.cx + lx * .11, .3); e.ball.position.y = lerp(e.ball.position.y, 2.95 + ly * .1, .3); });
    // arms
    let pose = S.pose; if (pose === "rest") { if (S.y > .05) pose = "up"; else if (abs(S.th) > .22 || abs(S.wy) > 3) pose = "out"; }
    arms.forEach(a => { let p = POSE[pose]; const flail = (pose === "out") ? .3 * sin(S.t * 16 + a.side) : 0, lean = pose === "out" ? S.th * a.side * .9 : 0;
      tmpV.copy(p[0]); a.E.lerp(tmpV, .22); tmpV.copy(p[1]); tmpV.y += flail + lean; a.H.lerp(tmpV, .22);
      limb(a.up, S0, a.E); a.el.position.copy(a.E); limb(a.fo, a.E, a.H); a.hand.position.copy(a.H); a.hand.quaternion.setFromUnitVectors(UP, tmpV.copy(a.H).sub(a.E).normalize());
      const fl = pose === "flex" ? 1 + .08 * sin(S.t * 7) : .001; a.bi.position.copy(S0).add(a.E).multiplyScalar(.5).add(V(.05, .22, 0)); a.bi.scale.set(1.2 * fl, .9 * fl, .95 * fl); a.bi.visible = pose === "flex"; });
    // shoes
    const down = S.mode !== "up", air = S.y > .02;
    feet.forEach(f => { const step = abs(S.vx) > .5 && !air ? Math.max(0, sin(S.t * 18 + (f.s > 0 ? PI : 0))) * .18 : 0; let fy = S.y + step, fx2 = f.s * .74, rz = 0;
      if (down || abs(S.th) > .5) { const c = cos(S.th), sn = sin(S.th); fx2 = f.s * .74 * c - .0 * sn; fy = S.y + 1.45 * abs(sn) + f.s * .74 * sn; fx2 += -(-.0) ; rz = S.th; f.g.position.set(f.s * .74 * c, Math.max(0, fy), -.1); }
      else f.g.position.set(fx2, fy, -.1);
      f.g.rotation.z = rz; f.g.rotation.x = (f.s > 0 ? -S.tap * .24 : 0) + (air ? .35 : 0) + (S.flipDur > 0 ? flip.rotation.x : 0); });
    if (S.flipDur > 0) { feet.forEach(f => { const a = flip.rotation.x, cy = 2.85, y0 = -2.85, z0 = -.1; f.g.position.y = S.y + cy + y0 * cos(a) - z0 * sin(a); f.g.position.z = y0 * sin(a) + z0 * cos(a); }); }
    else feet.forEach(f => { f.g.position.z = -.1; });
    // extras
    const dz = S.dizzy > 0; stars.forEach((m, i) => { m.visible = dz; if (!dz) return; const a = S.t * 3.4 + i * 2 * PI / 5; U.localToWorld(tmpV.set(cos(a) * 1.9, 5.7 + .15 * sin(S.t * 5 + i), sin(a) * 1.2)); m.position.copy(tmpV); m.scale.setScalar(.32); m.rotation.z = S.t * 3; });
    for (let i = puffs.length - 1; i >= 0; i--) { const m = puffs[i], u = m.userData; u.t += dt; if (u.t < 0) continue; m.position.addScaledVector(u.v, dt); m.scale.setScalar(.14 + u.t * .35); m.material.opacity = Math.max(0, .9 - u.t * .8); if (u.t > 1.15) { fx.remove(m); m.material.dispose(); puffs.splice(i, 1); } }
    // word bubble follows his roof
    if (S.sayT > 0) { U.localToWorld(tmpV.set(0, 5.7, 0)); tmpV.y = Math.max(tmpV.y, 2.2); tmpV.project(cam); const r = stage.getBoundingClientRect(); sayEl.style.left = clamp((tmpV.x + 1) / 2 * r.width, r.width * .22, r.width * .78) + "px"; sayEl.style.top = clamp((1 - tmpV.y) / 2 * r.height - 6, r.height * .2, r.height - 10) + "px"; }
    hitBox(); renderer.render(scene, cam); if (!shown) { shown = true; sp.classList.add("live-on"); } requestAnimationFrame(frame); }
  setPose("flex", 1.6); requestAnimationFrame(frame);
  return { destroy, state: S, poke, resize: px => { PX = Math.max(40, Math.min(400, +px || 120)); size(); } };
}
window.EcoLive = { mount };
})();
