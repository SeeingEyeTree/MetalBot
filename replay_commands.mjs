// Dumps a replay's human COMMAND/SELECT/STARTPOS packets (with game seconds) as JSON: node replay_commands.mjs <replay.sdfz> <out.json>
import { DemoParser } from "sdfz-demo-parser";
import fs from "fs";
const p = new DemoParser({ skipPackets: false });
const out = [];
p.onPacket.add((pk) => {
  const n = pk.name; 
  if (n==='STARTPOS') out.push({n,t:pk.actualGameTime,...pk.data}); if (n==='COMMAND'||n==='SELECT'||n==='CHAT'||n==='PLAYERNAME') out.push({n, t:pk.actualGameTime, ...pk.data});
  else if (n==='CHAT') out.push(pk);
});
const demo = await p.parseDemo(process.argv[2]);
console.log(JSON.stringify(demo.info.players.map(x=>({id:x.playerId??x.id,name:x.name,team:x.teamId}))));
fs.writeFileSync(process.argv[3], JSON.stringify(out));
console.log(out.length, JSON.stringify(out.slice(0,3)).slice(0,600), JSON.stringify(out.filter(o=>o.n==='COMMAND').slice(0,3)).slice(0,800));
