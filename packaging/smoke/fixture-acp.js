#!/usr/bin/env node
"use strict";
const fs = require('node:fs');
const readline = require('node:readline');
const root = process.env.TB_PACKAGED_SMOKE_ROOT;
if (!root) process.exit(64);
const marker = root + '/packaged-smoke-only';
if (!fs.existsSync(marker) || !process.env.CLAUDE_CONFIG_DIR?.startsWith(root + '/base/')) process.exit(64);
const send = msg => process.stdout.write(JSON.stringify({jsonrpc:'2.0',...msg})+'\n');
const options = {configOptions:[
  {id:'model',category:'model',name:'Model',type:'select',currentValue:'claude-sonnet-5',
   options:[{value:'claude-sonnet-5',name:'Synthetic Sonnet'}]},
  {id:'effort',name:'Effort',type:'select',currentValue:'medium',options:[{value:'medium',name:'Medium'}]}
]};
let serial=0;
readline.createInterface({input:process.stdin}).on('line',line=>{
  const m=JSON.parse(line), p=m.params||{};
  const reply = result=>send({id:m.id,result});
  switch(m.method) {
    case 'initialize':
      return reply({protocolVersion:1,agentCapabilities:{loadSession:true},agentInfo:{name:'synthetic-stock-chat',version:'1.0.0'}});
    case 'session/new': return reply({sessionId:'synthetic-'+process.pid+'-'+(++serial),...options});
    case 'session/load': return reply(options);
    case 'session/set_mode': return reply({});
    case 'session/set_config_option': return reply(options);
    case 'session/prompt': {
      const prompt=(p.prompt||[]).map(x=>x.text||'').join('\n');
      const which=prompt.includes('Generated stock Chat request Alpha')?'Alpha':
                  prompt.includes('Generated stock Chat request Bravo')?'Bravo':null;
      if (which) {
        fs.appendFileSync(root + '/fixture-turns.log',which+'\n');
        send({method:'session/update',params:{sessionId:p.sessionId,
          update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:
            'Generated stand-in response '+which+''}}}});
      }
      return reply({stopReason:'end_turn'});
    }
    case 'session/close': return reply({});
    case 'session/cancel': return;
    default:
      if (m.id!==undefined) send({id:m.id,error:{code:-32601,message:'unsupported generated ACP method'}});
  }
});
