exports.run = {
   usage: ['totalchat', 'resettc'],
   use: 'totalchat',
   category: 'group',
   async: async (m, {
      client,
      command,
      participants,
      groupSet,
      Func
   }) => {
      try {
         if (command === 'totalchat') {
            let data = []
            for (let jid of participants.map(v => v.id)) {
               if (groupSet?.member?.[jid] && groupSet?.member?.[jid]?.chat > 0) data.push({
                  jid: jid,
                  count: groupSet?.member?.[jid]?.chat
               })
            }
            if (data.length < 1) return client.reply(m.chat, Func.texted('bold', `🚩 There is no chat for this group yet.`), m)
            let text = data.sort((a, b) => b.count - a.count).map(v => `- @${client.decodeJid(v.jid).replace(/@.+/, '')} : ${v.count}`).join`\n`
            return client.reply(m.chat, `${text}`, m)
         } else if (command === 'resettc') {
            for (let jid in groupSet.member) {
               if (participants.map(v => v.id).includes(jid)) {
                  groupSet.member[jid].chat = 0
               } else {
                  delete groupSet.member[jid]
               }
            }
            return client.reply(m.chat, Func.texted('bold', `🚩 Total chat has been reset.`), m)
         }
      } catch {
         client.reply(m.chat, global.status.error, m)
      }
   },
   error: false,
   group: true
}