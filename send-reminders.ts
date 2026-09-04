// Supabase Edge Function: send-reminders
//
// Set up a scheduled trigger separately (Supabase Dashboard → Database →
// Cron Jobs, using pg_cron + pg_net to POST to this function's URL — see
// README.md). This function itself decides whether today is actually one
// of the admin-picked notification days (app_settings.notify_days, set
// from the app's Admin screen); if not, it exits immediately and sends
// nothing. On a scheduled day, each person with anything pending gets ONE
// digest push — not one push per item — listing their stale tasks,
// unacknowledged comments (task-level and job-level), and due/overdue
// reminders. Re-invoking this function more than once on the same
// scheduled day won't double-send: dedup is a per-person, per-day check
// against notification_log rather than a per-item throttle.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

Deno.serve(async (req) => {
  try {
    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    );

    const publicKey = Deno.env.get('VAPID_PUBLIC_KEY')!;
    const privateKey = Deno.env.get('VAPID_PRIVATE_KEY')!;
    // Required by the Web Push spec — put a real contact address here (an
    // admin/support email for this deployment), not the placeholder below.
    webpush.setVapidDetails('mailto:admin@example.com', publicKey, privateKey);

    const { data: settings } = await sb.from('app_settings').select('wa_threshold, notify_days, company_name').single();
    const threshold = settings?.wa_threshold ?? 5;
    const notifyDays: number[] = settings?.notify_days ?? [1, 2, 3, 4, 5];
    const appName = settings?.company_name || 'Workline';

    const today = new Date();
    const todayWeekday = today.getUTCDay(); // 0=Sun .. 6=Sat, matches the app's day picker
    if (!notifyDays.includes(todayWeekday)) {
      return new Response(JSON.stringify({ skipped: 'not a scheduled day', todayWeekday, notifyDays }), {
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const daysAgoISO = (n: number) => { const d = new Date(today); d.setDate(d.getDate() - n); return d.toISOString(); };
    const daysAgoDate = (n: number) => daysAgoISO(n).slice(0, 10);
    const staleCutoffDate = daysAgoDate(threshold);   // how old a task/comment must be before it counts
    const todayDate = today.toISOString().slice(0, 10);
    const todayStartISO = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate())).toISOString();

    const [people, tasks, taskComments, jobComments, jobs, reminders, subs, digestedToday] = await Promise.all([
      sb.from('people').select('id, name, is_admin'),
      sb.from('tasks').select('id, job_id, name, owner_name, days, status, actual_start, planned_start').neq('status', 'completed'),
      sb.from('task_comments').select('id, task_id, author, acked, created_at').eq('acked', false),
      sb.from('job_comments').select('id, job_id, author, acked, created_at').eq('acked', false),
      sb.from('jobs').select('id, code, on_hold'),
      sb.from('task_reminders').select('id, task_id, text, due_date, status').eq('status', 'open'),
      sb.from('push_subscriptions').select('*'),
      sb.from('notification_log').select('person_id').eq('item_type', 'digest').gte('sent_at', todayStartISO),
    ]).then(rs => rs.map(r => r.data || []));

    const jobCode = (jid: string) => jobs.find((j: any) => j.id === jid)?.code || '';
    const taskById = (tid: string) => tasks.find((t: any) => t.id === tid);
    const personByName = (name: string) => people.find((p: any) => p.name === name);
    const subsFor = (personId: string) => subs.filter((s: any) => s.person_id === personId);
    const alreadyDigestedToday = (personId: string) => digestedToday.some((d: any) => d.person_id === personId);

    // person name -> list of plain-text lines describing what's pending for them
    const pending = new Map<string, string[]>();
    const addLine = (personName: string, line: string) => {
      if (!pending.has(personName)) pending.set(personName, []);
      pending.get(personName)!.push(line);
    };

    // stale tasks — skipped entirely for a paused job, same as the app's own
    // display: time spent on hold was never the owner's fault, so it shouldn't
    // accrue as "stale" while frozen
    for (const t of tasks) {
      if (!t.owner_name) continue;
      if (jobs.find((j: any) => j.id === t.job_id)?.on_hold) continue;
      let stale = false;
      if (t.status === 'pending' && t.planned_start && t.planned_start <= staleCutoffDate) stale = true;
      if (t.status === 'in_progress' && t.actual_start) {
        const elapsedDays = Math.floor((today.getTime() - new Date(t.actual_start).getTime()) / 86400000);
        if (elapsedDays > (t.days || 1)) stale = true;
      }
      if (!stale) continue;
      addLine(t.owner_name, `${jobCode(t.job_id)}: "${t.name}" needs attention`);
    }

    // unacknowledged task comments
    for (const c of taskComments) {
      if (c.created_at > staleCutoffDate + 'T23:59:59') continue; // not old enough yet
      const task = taskById(c.task_id);
      if (!task || !task.owner_name || c.author === task.owner_name) continue;
      addLine(task.owner_name, `${c.author} commented on "${task.name}" (${jobCode(task.job_id)}) — unread`);
    }

    // unacknowledged job comments — jobs have no single owner, so every admin gets these
    const adminNames = people.filter((p: any) => p.is_admin).map((p: any) => p.name);
    for (const c of jobComments) {
      if (c.created_at > staleCutoffDate + 'T23:59:59') continue; // not old enough yet
      for (const adminName of adminNames) {
        if (c.author === adminName) continue;
        addLine(adminName, `${c.author} commented on job ${jobCode(c.job_id)} — unread`);
      }
    }

    // due / overdue reminders
    for (const r of reminders) {
      if (!r.due_date || r.due_date > todayDate) continue;
      const task = taskById(r.task_id);
      if (!task || !task.owner_name) continue;
      addLine(task.owner_name, `Reminder due: "${r.text}" (${jobCode(task.job_id)})`);
    }

    let sent = 0, skippedAlreadyToday = 0, noSubscription = 0, failed = 0;

    for (const [personName, lines] of pending) {
      const person = personByName(personName);
      if (!person) continue;
      if (alreadyDigestedToday(person.id)) { skippedAlreadyToday++; continue; }
      const targetSubs = subsFor(person.id);
      if (targetSubs.length === 0) { noSubscription++; continue; }

      const body = `${lines.length} thing${lines.length !== 1 ? 's' : ''} need your attention:\n` + lines.map(l => `• ${l}`).join('\n');
      for (const sub of targetSubs) {
        try {
          await webpush.sendNotification(
            { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
            JSON.stringify({ title: appName, body, tag: `digest-${person.id}` })
          );
        } catch (err: any) {
          failed++;
          if (err?.statusCode === 404 || err?.statusCode === 410) {
            await sb.from('push_subscriptions').delete().eq('id', sub.id);
          }
        }
      }
      await sb.from('notification_log').insert({ person_id: person.id, item_type: 'digest', item_id: person.id });
      sent++;
    }

    return new Response(JSON.stringify({ sent, skippedAlreadyToday, noSubscription, failed, todayWeekday }), {
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: { 'Content-Type': 'application/json' } });
  }
});
