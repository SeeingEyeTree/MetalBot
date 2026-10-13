# Economy numbers (measured / given by the user)

- **Metal extractor yield on Full Metal Plate (user, 2026-10-12):** T1 mex (`cormex`) = **2.37 metal/s**, T2 mex (`cormoho`) = **9.48 metal/s** (4x).
  Check against a game: 946 mexes at 20:00 gave 2629 avg income -> 2.78 per mex, i.e. ~6% of them are T2.
- Fusion (`corfus`): +850 energy/s, 3600 metal + 22000 energy, 59000 build time. Advanced fusion (`corafus`): +3000 energy/s, 9700 m + 48000 E.
- Dragon (`corcrwh`): 5100 metal, 72000 energy, 120000 build time -> **14.1 energy per metal**, 23.5 build power per metal/s.
  Spending M metal/s on Dragons needs 14.1 x M energy/s and 23.5 x M build power; at 2600 m/s that is 36.7k E/s (43 fusions) and 61k BP (306 nanos).
- Nano turret: 200 BP, 230 metal + 3200 energy.
- Tracker: compare runs on `metal_inc_avg` / `energy_inc_avg` / `*_pull_avg` (the minute-mark `metal_inc` is a noisy sample).
