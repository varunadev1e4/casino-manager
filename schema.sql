-- PARTY BANK v3 schema (fresh install). Run once in Supabase > SQL Editor.
-- No sign-in needed (Anonymous sign-ins can stay off). Viewers are read-only;
-- super admin / co-host unlock with a code that is checked on the server for every action.
--
-- !!! CHANGE BOTH CODES BELOW BEFORE RUNNING (use long ones) !!!
-- (this resets everything: players, bets, ledger)

drop table if exists ledger, entries, bets, bank, players, profiles, settings, event cascade;
drop sequence if exists adj_seq;
drop function if exists need(text), is_staff(), join_party(text), claim_super(text), set_role(uuid,text),
  adjust(uuid,int,text), create_bet(text,text,text,jsonb), set_status(bigint,text),
  place_entry(bigint,uuid,int,int), cancel_entry(bigint), settle_bet(bigint,int),
  void_bet(bigint), reopen_bet(bigint);
drop function if exists rescue_loan(text,bigint,int), place_entry(text,bigint,bigint,int,int), cancel_entry(text,bigint), set_status(text,bigint,text), create_bet(text,text,text,jsonb);

create table settings(key text primary key, value text not null);
insert into settings values
  ('super_code','Varun13#'),     -- you: everything
  ('helper_code','cohost13#'),   -- co-host: everything except event settings and start clean (reset/delete)
  ('start_tokens','1000');

create sequence adj_seq;
create table players(id bigserial primary key, name text not null,
  balance int not null default 0, loan int not null default 0, loan_taken boolean not null default false, created_at timestamptz default now());
create unique index players_name on players(lower(name));
create table bank(id int primary key default 1 check(id=1), balance int not null);
insert into bank values(1,10000);
-- mode 'pvp' : two players put the same stake, winner takes 2 x stake.
-- mode 'bank': one player vs the bank, same stake, winner takes 2 x stake.
create table bets(id bigserial primary key, game text, title text not null,
  mode text not null check(mode in('bank','pvp')), options jsonb not null, stake int,
  status text not null default 'open' check(status in('open','locked','settled','void')),
  winning int, draw boolean not null default false, created_at timestamptz default now());
create table entries(id bigserial primary key, bet_id bigint not null references bets on delete cascade,
  player_id bigint not null references players, opt int not null, stake int not null check(stake>0),
  payout int, created_at timestamptz default now());
create table ledger(id bigserial primary key, player_id bigint, delta int not null,
  reason text, bet_id bigint, adj_batch bigint, undone boolean not null default false,
  created_at timestamptz default now());
create table event(id int primary key default 1 check(id=1), ended boolean not null default false,
  prizes jsonb not null default '[]', final jsonb, max_stake int not null default 500, show_economy boolean not null default true, staff_cards jsonb not null default '[]');
insert into event(id) values(1);

-- Everyone can read (except settings = codes). Nobody can write directly; all writes go through the functions below.
alter table settings enable row level security;
alter table players enable row level security;
alter table bank enable row level security;
alter table bets enable row level security;
alter table entries enable row level security;
alter table ledger enable row level security;
alter table event enable row level security;
create policy r on players for select to anon, authenticated using(true);
create policy r on bank for select to anon, authenticated using(true);
create policy r on bets for select to anon, authenticated using(true);
create policy r on entries for select to anon, authenticated using(true);
create policy r on ledger for select to anon, authenticated using(true);
create policy r on event for select to anon, authenticated using(true);

create or replace function check_code(p_code text) returns text language plpgsql security definer set search_path=public as $$
begin
  if p_code is not distinct from (select value from settings where key='super_code') then return 'super'; end if;
  if p_code is not distinct from (select value from settings where key='helper_code') then return 'helper'; end if;
  raise exception 'Wrong code';
end $$;

create or replace function need(p_code text, lvl text) returns void language plpgsql security definer set search_path=public as $$
declare r text;
begin r:=check_code(p_code);
  if lvl='super' and r<>'super' then raise exception 'Super admin only'; end if;
end $$;

-- Internal helper: moves tokens in/out of the bank AND writes the ledger row in one step.
-- Not callable from the browser.
create or replace function bank_move(p_delta int, p_reason text, p_bet bigint default null, p_batch bigint default null) returns void language plpgsql security definer set search_path=public as $$
begin
  if coalesce(p_delta,0)=0 then return; end if;
  update bank set balance=balance+p_delta where id=1;
  insert into ledger(player_id,delta,reason,bet_id,adj_batch) values(null,p_delta,p_reason,p_bet,p_batch);
end $$;
revoke execute on function bank_move(int,text,bigint,bigint) from public, anon, authenticated;

-- Co-host or super: add everyone who is present (duplicates skipped).
create or replace function add_players(p_code text, p_names text[]) returns void language plpgsql security definer set search_path=public as $$
declare t int; n text; pid bigint;
begin perform need(p_code,'helper');
  select value::int into t from settings where key='start_tokens';
  foreach n in array p_names loop
    n:=trim(n); continue when n='';
    begin
      insert into players(name,balance) values(n,t) returning id into pid;
      insert into ledger(player_id,delta,reason) values(pid,t,'Welcome tokens');
    exception when unique_violation then null;
    end;
  end loop;
end $$;

-- Co-host or super: remove player, adjust tokens, bank wallet, undo, loans, undo result.
-- Super only: set_event, end_event, reset_event (event settings + start clean).
create or replace function remove_player(p_code text, p_id bigint) returns void language plpgsql security definer set search_path=public as $$
begin perform need(p_code,'helper');
  if exists(select 1 from entries where player_id=p_id) then raise exception 'Player has bets - void them first'; end if;
  delete from ledger where player_id=p_id;
  delete from players where id=p_id;
end $$;

create or replace function adjust(p_code text, p_players bigint[], p_delta int, p_reason text) returns void language plpgsql security definer set search_path=public as $$
declare x bigint; old int; d int; bt bigint:=nextval('adj_seq'); r text:=coalesce(nullif(trim(p_reason),''),'Host adjustment');
begin perform need(p_code,'helper');
  if coalesce(p_delta,0)=0 then raise exception 'Enter an amount'; end if;
  foreach x in array p_players loop
    select balance into old from players where id=x for update;
    if not found then continue; end if;
    d:=greatest(old+p_delta,0)-old;           -- balance never goes below 0
    if d=0 then continue; end if;
    update players set balance=old+d where id=x;
    insert into ledger(player_id,delta,reason,adj_batch) values(x,d,r,bt);
  end loop;
end $$;

create or replace function bank_adjust(p_code text, p_delta int, p_reason text) returns void language plpgsql security definer set search_path=public as $$
begin perform need(p_code,'helper');
  if coalesce(p_delta,0)=0 then raise exception 'Enter an amount'; end if;
  if (select balance from bank where id=1)+p_delta<0 then raise exception 'Bank cannot go below 0'; end if;
  perform bank_move(p_delta,coalesce(nullif(trim(p_reason),''),'Bank top-up'),null,nextval('adj_seq'));
end $$;

-- Reverses the most recent adjustment batch (players and/or bank).
create or replace function undo_adjust(p_code text) returns void language plpgsql security definer set search_path=public as $$
declare bt bigint; r ledger%rowtype; cur int; d int;
begin perform need(p_code,'helper');
  select max(adj_batch) into bt from ledger where adj_batch is not null and not undone;
  if bt is null then raise exception 'Nothing to undo'; end if;
  for r in select * from ledger where adj_batch=bt loop
    if r.player_id is null then
      perform bank_move(-r.delta,'Undo: '||coalesce(r.reason,'adjustment'));
    else
      select balance into cur from players where id=r.player_id for update;
      if not found then continue; end if;
      d:=greatest(cur-r.delta,0)-cur;
      update players set balance=cur+d where id=r.player_id;
      if d<>0 then insert into ledger(player_id,delta,reason) values(r.player_id,d,'Undo: '||coalesce(r.reason,'adjustment')); end if;
    end if;
  end loop;
  update ledger set undone=true where adj_batch=bt;
end $$;

-- Duel vs player: both stake the same amount now; winner gets 2x stake.
create or replace function create_pvp(p_code text, p_game text, p_title text, p_a bigint, p_b bigint, p_stake int) returns void language plpgsql security definer set search_path=public as $$
declare na text; nb text; ba int; bb int; bid bigint; mx int; ended boolean;
begin perform need(p_code,'helper');
  select max_stake,event.ended into mx,ended from event where id=1;
  if ended then raise exception 'Event has ended'; end if;
  if p_a=p_b then raise exception 'Pick two different players'; end if;
  if coalesce(p_stake,0)<=0 then raise exception 'Stake must be positive'; end if;
  if mx>0 and p_stake>mx then raise exception 'Max stake is % tokens',mx; end if;
  select name,balance into na,ba from players where id=p_a for update;
  select name,balance into nb,bb from players where id=p_b for update;
  if na is null or nb is null then raise exception 'Player not found'; end if;
  if ba<p_stake or bb<p_stake then raise exception 'Both players need at least % tokens',p_stake; end if;
  insert into bets(game,title,mode,options,stake,status) values(p_game,p_title,'pvp',jsonb_build_array(na,nb),p_stake,'locked') returning id into bid;
  update players set balance=balance-p_stake where id in(p_a,p_b);
  insert into entries(bet_id,player_id,opt,stake) values(bid,p_a,0,p_stake),(bid,p_b,1,p_stake);
  insert into ledger(player_id,delta,reason,bet_id) values(p_a,-p_stake,'Duel: '||p_title,bid),(p_b,-p_stake,'Duel: '||p_title,bid);
end $$;

-- Player vs Bank: the stake goes INTO the bank now; if the player wins the bank pays out 2x stake.
create or replace function create_bank_bet(p_code text, p_game text, p_title text, p_player bigint, p_stake int) returns void language plpgsql security definer set search_path=public as $$
declare n text; bal int; bid bigint; mx int; ended boolean; bk int;
begin perform need(p_code,'helper');
  select max_stake,event.ended into mx,ended from event where id=1;
  if ended then raise exception 'Event has ended'; end if;
  if coalesce(p_stake,0)<=0 then raise exception 'Stake must be positive'; end if;
  if mx>0 and p_stake>mx then raise exception 'Max stake is % tokens',mx; end if;
  select name,balance into n,bal from players where id=p_player for update;
  if n is null then raise exception 'Player not found'; end if;
  if bal<p_stake then raise exception '% only has % tokens',n,bal; end if;
  select balance into bk from bank where id=1 for update;
  if bk<p_stake then raise exception 'Bank cannot cover this bet - top it up first'; end if;
  insert into bets(game,title,mode,options,stake,status) values(p_game,p_title,'bank',jsonb_build_array(n,'🏦 Bank'),p_stake,'locked') returning id into bid;
  update players set balance=balance-p_stake where id=p_player;
  insert into entries(bet_id,player_id,opt,stake) values(bid,p_player,0,p_stake);
  insert into ledger(player_id,delta,reason,bet_id) values(p_player,-p_stake,'Bet vs Bank: '||p_title,bid);
  perform bank_move(p_stake,'Stake from '||n||': '||p_title,bid);
end $$;

create or replace function settle_bet(p_code text, p_bet bigint, p_win int) returns void language plpgsql security definer set search_path=public as $$
declare b bets%rowtype; e entries%rowtype; pay int; tp int:=0;
begin perform need(p_code,'helper');
  select * into b from bets where id=p_bet for update;
  if b.status in('settled','void') then raise exception 'Already closed'; end if;
  if p_win<0 or p_win>=jsonb_array_length(b.options) then raise exception 'bad option'; end if;
  for e in select * from entries where bet_id=p_bet loop
    pay:=case when e.opt=p_win then e.stake*2 else 0 end;
    update entries set payout=pay where id=e.id;
    if pay>0 then
      update players set balance=balance+pay where id=e.player_id;
      insert into ledger(player_id,delta,reason,bet_id) values(e.player_id,pay,'Won: '||b.title,p_bet);
    end if;
    tp:=tp+pay;
  end loop;
  if b.mode='bank' then perform bank_move(-tp,'Payout: '||b.title,p_bet); end if;
  update bets set status='settled',winning=p_win where id=p_bet;
end $$;

create or replace function void_bet(p_code text, p_bet bigint) returns void language plpgsql security definer set search_path=public as $$
declare b bets%rowtype; e entries%rowtype; ts int:=0;
begin perform need(p_code,'helper');
  select * into b from bets where id=p_bet for update;
  if b.status in('settled','void') then raise exception 'Already closed'; end if;
  for e in select * from entries where bet_id=p_bet loop
    update players set balance=balance+e.stake where id=e.player_id;
    update entries set payout=e.stake where id=e.id;
    insert into ledger(player_id,delta,reason,bet_id) values(e.player_id,e.stake,'Refund: '||b.title,p_bet);
    ts:=ts+e.stake;
  end loop;
  if b.mode='bank' then perform bank_move(-ts,'Refund: '||b.title,p_bet); end if;
  update bets set status='void' where id=p_bet;
end $$;

create or replace function reopen_bet(p_code text, p_bet bigint) returns void language plpgsql security definer set search_path=public as $$
declare b bets%rowtype; e entries%rowtype; tp int:=0;
begin perform need(p_code,'helper');
  select * into b from bets where id=p_bet for update;
  if b.status<>'settled' then raise exception 'Not settled'; end if;
  for e in select * from entries where bet_id=p_bet loop
    if coalesce(e.payout,0)>0 then
      update players set balance=balance-e.payout where id=e.player_id;
      insert into ledger(player_id,delta,reason,bet_id) values(e.player_id,-e.payout,'Result reversed',p_bet);
      tp:=tp+e.payout;
    end if;
  end loop;
  if b.mode='bank' then perform bank_move(tp,'Result reversed: '||b.title,p_bet); end if;
  update entries set payout=null where bet_id=p_bet;
  update bets set status='locked',winning=null where id=p_bet;
end $$;

-- Rescue loan from the bank to a broke player. Loans count against them in the ranking (net = tokens - loan).
-- One-time rescue loan: exactly 100 tokens from the bank, only for players under 50 tokens, once per player.
create or replace function rescue_loan(p_code text, p_player bigint) returns void language plpgsql security definer set search_path=public as $$
declare n text; bal int; used boolean; amt constant int:=100;
begin perform need(p_code,'helper');
  select name,balance,loan_taken into n,bal,used from players where id=p_player for update;
  if n is null then raise exception 'Player not found'; end if;
  if used then raise exception '% already used their one-time loan',n; end if;
  if bal>=50 then raise exception '% is not broke (loans are for players under 50 tokens)',n; end if;
  if (select balance from bank where id=1)<amt then raise exception 'Bank cannot cover this loan'; end if;
  update players set balance=balance+amt, loan=loan+amt, loan_taken=true where id=p_player;
  insert into ledger(player_id,delta,reason) values(p_player,amt,'Rescue loan');
  perform bank_move(-amt,'Rescue loan to '||n);
end $$;

create or replace function repay_loan(p_code text, p_player bigint) returns void language plpgsql security definer set search_path=public as $$
declare n text; bal int; ln int; r int;
begin perform need(p_code,'helper');
  select name,balance,loan into n,bal,ln from players where id=p_player for update;
  if n is null then raise exception 'Player not found'; end if;
  r:=least(bal,ln);
  if r<=0 then raise exception 'Nothing to repay'; end if;
  update players set balance=balance-r, loan=loan-r where id=p_player;
  insert into ledger(player_id,delta,reason) values(p_player,-r,'Loan repaid');
  perform bank_move(r,'Loan repaid by '||n);
end $$;

create or replace function set_event(p_code text, p_prizes jsonb, p_max_stake int) returns void language plpgsql security definer set search_path=public as $$
begin perform need(p_code,'super');
  update event set prizes=coalesce(p_prizes,'[]'::jsonb), max_stake=greatest(coalesce(p_max_stake,0),0) where id=1;
end $$;

create or replace function end_event(p_code text, p_end boolean) returns void language plpgsql security definer set search_path=public as $$
begin perform need(p_code,'super');
  if p_end then
    if exists(select 1 from bets where status in('open','locked')) then raise exception 'Settle or void live bets first'; end if;
    update event set ended=true, final=(select coalesce(jsonb_agg(jsonb_build_object('id',pl.id,'name',pl.name,'balance',pl.balance,'loan',pl.loan,'net',pl.balance-pl.loan) order by pl.balance-pl.loan desc, pl.name),'[]'::jsonb) from players pl) where id=1;
  else
    update event set ended=false, final=null where id=1;
  end if;
end $$;

-- Start clean. p_keep_players=true: everyone back to starting tokens. false: delete players too.
create or replace function reset_event(p_code text, p_keep_players boolean) returns void language plpgsql security definer set search_path=public as $$
declare t int;
begin perform need(p_code,'super');
  select value::int into t from settings where key='start_tokens';
  delete from entries where true;
  delete from bets where true;
  delete from ledger where true;
  update bank set balance=10000 where id=1;
  update event set ended=false, final=null where id=1;
  if p_keep_players then
    update players set balance=t, loan=0, loan_taken=false where true;
    insert into ledger(player_id,delta,reason) select id,t,'Welcome tokens' from players;
  else
    delete from players where true;
  end if;
end $$;

-- Super admin: hide / show the Economy tab for guests.
create or replace function set_economy(p_code text, p_show boolean) returns void language plpgsql security definer set search_path=public as $$
begin perform need(p_code,'super');
  update event set show_economy=coalesce(p_show,true) where id=1;
end $$;

-- Super admin: save the special (host team) card details.
create or replace function set_staff_cards(p_code text, p_cards jsonb) returns void language plpgsql security definer set search_path=public as $$
begin perform need(p_code,'super');
  if jsonb_typeof(p_cards)<>'array' or jsonb_array_length(p_cards)>60 then raise exception 'Invalid card list'; end if;
  update event set staff_cards=p_cards where id=1;
end $$;

-- Co-host or super: rename a player. Also fixes the name inside their duels, default duel titles, history lines and the frozen final leaderboard.
create or replace function rename_player(p_code text, p_id bigint, p_name text) returns void language plpgsql security definer set search_path=public as $$
declare old text; nn text:=trim(coalesce(p_name,'')); e record; b bets%rowtype; o0 text; o1 text; def text; newt text;
begin perform need(p_code,'helper');
  if nn='' then raise exception 'Enter a name'; end if;
  select name into old from players where id=p_id for update;
  if old is null then raise exception 'Player not found'; end if;
  if nn=old then return; end if;
  begin
    update players set name=nn where id=p_id;
  exception when unique_violation then
    raise exception 'Someone is already called %',nn;
  end;
  for e in select bet_id, opt from entries where player_id=p_id loop
    select * into b from bets where id=e.bet_id for update;
    def:=(b.options->>0)||' vs '||case when b.mode='bank' then 'Bank' else (b.options->>1) end;
    o0:=case when e.opt=0 then nn else b.options->>0 end;
    o1:=case when e.opt=1 then nn else b.options->>1 end;
    newt:=case when b.title=def then o0||' vs '||case when b.mode='bank' then 'Bank' else o1 end else b.title end;
    update bets set options=jsonb_build_array(o0,o1), title=newt where id=b.id;
    if newt<>b.title then
      update ledger set reason=replace(reason,b.title,newt) where bet_id=b.id;
    end if;
  end loop;
  update ledger set reason=replace(reason,'Stake from '||old||': ','Stake from '||nn||': ') where player_id is null and reason like 'Stake from %';
  update ledger set reason='Rescue loan to '||nn where player_id is null and reason='Rescue loan to '||old;
  update ledger set reason='Loan repaid by '||nn where player_id is null and reason='Loan repaid by '||old;
  update event set final=coalesce((select jsonb_agg(case when (x.v->>'id')::bigint=p_id then jsonb_set(x.v,'{name}',to_jsonb(nn)) else x.v end order by x.ord)
      from jsonb_array_elements(final) with ordinality as x(v,ord)),final)
    where id=1 and final is not null and jsonb_typeof(final)='array';
end $$;

-- Co-host or super: call a live duel / bank bet a draw. Everyone gets their stake back and it is shown as "draw" (not "void").
create or replace function draw_bet(p_code text, p_bet bigint) returns void language plpgsql security definer set search_path=public as $$
declare b bets%rowtype; e entries%rowtype; ts int:=0;
begin perform need(p_code,'helper');
  select * into b from bets where id=p_bet for update;
  if not found then raise exception 'Bet not found'; end if;
  if b.status in('settled','void') then raise exception 'Already closed'; end if;
  for e in select * from entries where bet_id=p_bet loop
    update players set balance=balance+e.stake where id=e.player_id;
    update entries set payout=e.stake where id=e.id;
    insert into ledger(player_id,delta,reason,bet_id) values(e.player_id,e.stake,'Refund (draw): '||b.title,p_bet);
    ts:=ts+e.stake;
  end loop;
  if b.mode='bank' then perform bank_move(-ts,'Refund (draw): '||b.title,p_bet); end if;
  update bets set status='void', draw=true where id=p_bet;
end $$;

alter publication supabase_realtime add table players, bank, bets, entries, ledger, event;