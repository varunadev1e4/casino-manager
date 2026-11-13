-- PARTY BANK v2 schema. Run once in Supabase > SQL Editor.
-- No sign-in needed anymore (Anonymous sign-ins can stay off). Viewers are read-only;
-- the host/helper unlock with a code that is checked on the server for every action.
--
-- !!! CHANGE BOTH CODES BELOW BEFORE RUNNING !!!
-- (this resets everything: players, bets, ledger)

drop table if exists ledger, entries, bets, bank, players, profiles, settings cascade;
drop function if exists need(text), is_staff(), join_party(text), claim_super(text), set_role(uuid,text),
  adjust(uuid,int,text), create_bet(text,text,text,jsonb), set_status(bigint,text),
  place_entry(bigint,uuid,int,int), cancel_entry(bigint), settle_bet(bigint,int),
  void_bet(bigint), reopen_bet(bigint);

create table settings(key text primary key, value text not null);
insert into settings values
  ('super_code','Varun13#'),      -- you: full powers (adjust tokens, add/remove players, undo)
  ('helper_code','cohost13#'),   -- optional helper: add players, create/place/settle bets
  ('start_tokens','1000');

create table players(id bigserial primary key, name text not null,
  balance int not null default 0, created_at timestamptz default now());
create unique index players_name on players(lower(name));
create table bank(id int primary key default 1 check(id=1), balance int not null);
insert into bank values(1,10000);
-- mode 'bank': any number of players back an option, win = stake x2.
-- mode 'pvp' : two players put the same stake, winner takes 2 x stake.
create table bets(id bigserial primary key, game text, title text not null,
  mode text not null check(mode in('bank','pvp')), options jsonb not null, stake int,
  status text not null default 'open' check(status in('open','locked','settled','void')),
  winning int, created_at timestamptz default now());
create table entries(id bigserial primary key, bet_id bigint not null references bets on delete cascade,
  player_id bigint not null references players, opt int not null, stake int not null check(stake>0),
  payout int, created_at timestamptz default now());
create table ledger(id bigserial primary key, player_id bigint, delta int not null,
  reason text, bet_id bigint, created_at timestamptz default now());

-- Everyone can read. Nobody can write directly; all writes go through the functions below.
alter table settings enable row level security;   -- no policy = codes are never readable
alter table players enable row level security;
alter table bank enable row level security;
alter table bets enable row level security;
alter table entries enable row level security;
alter table ledger enable row level security;
create policy r on players for select to anon, authenticated using(true);
create policy r on bank for select to anon, authenticated using(true);
create policy r on bets for select to anon, authenticated using(true);
create policy r on entries for select to anon, authenticated using(true);
create policy r on ledger for select to anon, authenticated using(true);

create or replace function check_code(p_code text) returns text language plpgsql security definer set search_path=public as $$
begin
  if p_code is not distinct from (select value from settings where key='super_code') then return 'super'; end if;
  if p_code is not distinct from (select value from settings where key='helper_code') then return 'helper'; end if;
  raise exception 'Wrong code';
end $$;

create or replace function need(p_code text, lvl text) returns void language plpgsql security definer set search_path=public as $$
declare r text;
begin r:=check_code(p_code);
  if lvl='super' and r<>'super' then raise exception 'Host only'; end if;
end $$;

-- Host creates everyone who is present (one name per array item). Duplicates are skipped.
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

create or replace function remove_player(p_code text, p_id bigint) returns void language plpgsql security definer set search_path=public as $$
begin perform need(p_code,'super');
  if exists(select 1 from entries where player_id=p_id) then raise exception 'Player has bets - void them first'; end if;
  delete from ledger where player_id=p_id;
  delete from players where id=p_id;
end $$;

-- Add (+) or deduct (-) tokens for one or many players: late comers, early birds, etc.
create or replace function adjust(p_code text, p_players bigint[], p_delta int, p_reason text) returns void language plpgsql security definer set search_path=public as $$
declare x bigint; old int; d int;
begin perform need(p_code,'super');
  if coalesce(p_delta,0)=0 then raise exception 'Enter an amount'; end if;
  foreach x in array p_players loop
    select balance into old from players where id=x for update;
    if not found then continue; end if;
    d:=greatest(old+p_delta,0)-old;           -- balance never goes below 0
    if d=0 then continue; end if;
    update players set balance=old+d where id=x;
    insert into ledger(player_id,delta,reason) values(x,d,coalesce(nullif(p_reason,''),'Host adjustment'));
  end loop;
end $$;

-- Bet vs bank: options are a JSON array of labels. Correct pick pays exactly 2x stake.
create or replace function create_bet(p_code text, p_game text, p_title text, p_options jsonb) returns void language plpgsql security definer set search_path=public as $$
begin perform need(p_code,'helper');
  if jsonb_array_length(p_options)<2 then raise exception 'Need 2+ options'; end if;
  insert into bets(game,title,mode,options) values(p_game,p_title,'bank',p_options);
end $$;

-- Duel vs player: both stake the same amount now; winner gets 2x stake.
create or replace function create_pvp(p_code text, p_game text, p_title text, p_a bigint, p_b bigint, p_stake int) returns void language plpgsql security definer set search_path=public as $$
declare na text; nb text; ba int; bb int; bid bigint;
begin perform need(p_code,'helper');
  if p_a=p_b then raise exception 'Pick two different players'; end if;
  if coalesce(p_stake,0)<=0 then raise exception 'Stake must be positive'; end if;
  select name,balance into na,ba from players where id=p_a for update;
  select name,balance into nb,bb from players where id=p_b for update;
  if na is null or nb is null then raise exception 'Player not found'; end if;
  if ba<p_stake or bb<p_stake then raise exception 'Both players need at least % tokens',p_stake; end if;
  insert into bets(game,title,mode,options,stake,status) values(p_game,p_title,'pvp',jsonb_build_array(na,nb),p_stake,'locked') returning id into bid;
  update players set balance=balance-p_stake where id in(p_a,p_b);
  insert into entries(bet_id,player_id,opt,stake) values(bid,p_a,0,p_stake),(bid,p_b,1,p_stake);
  insert into ledger(player_id,delta,reason,bet_id) values(p_a,-p_stake,'Duel: '||p_title,bid),(p_b,-p_stake,'Duel: '||p_title,bid);
end $$;

create or replace function set_status(p_code text, p_bet bigint, p_status text) returns void language plpgsql security definer set search_path=public as $$
begin perform need(p_code,'helper');
  if p_status not in('open','locked') then raise exception 'bad status'; end if;
  update bets set status=p_status where id=p_bet and mode='bank' and status in('open','locked');
end $$;

create or replace function place_entry(p_code text, p_bet bigint, p_player bigint, p_opt int, p_stake int) returns void language plpgsql security definer set search_path=public as $$
declare b bets%rowtype; bal int;
begin perform need(p_code,'helper');
  select * into b from bets where id=p_bet for update;
  if b.mode<>'bank' then raise exception 'Duels are set up when created'; end if;
  if b.status<>'open' then raise exception 'Betting is closed'; end if;
  if p_opt<0 or p_opt>=jsonb_array_length(b.options) then raise exception 'bad option'; end if;
  select balance into bal from players where id=p_player for update;
  if bal is null then raise exception 'Player not found'; end if;
  if coalesce(p_stake,0)<=0 or p_stake>bal then raise exception 'Stake must be 1..% tokens', bal; end if;
  update players set balance=balance-p_stake where id=p_player;
  insert into entries(bet_id,player_id,opt,stake) values(p_bet,p_player,p_opt,p_stake);
  insert into ledger(player_id,delta,reason,bet_id) values(p_player,-p_stake,'Bet: '||b.title,p_bet);
end $$;

create or replace function cancel_entry(p_code text, p_entry bigint) returns void language plpgsql security definer set search_path=public as $$
declare e entries%rowtype; b bets%rowtype;
begin perform need(p_code,'helper');
  select * into e from entries where id=p_entry;
  if not found then raise exception 'Entry not found'; end if;
  select * into b from bets where id=e.bet_id for update;
  if b.mode<>'bank' or b.status<>'open' then raise exception 'Cannot cancel now'; end if;
  update players set balance=balance+e.stake where id=e.player_id;
  insert into ledger(player_id,delta,reason,bet_id) values(e.player_id,e.stake,'Bet cancelled: '||b.title,b.id);
  delete from entries where id=p_entry;
end $$;

-- Winners get exactly 2x stake. Bank takes losing stakes and pays winners' profit (duels net to 0).
create or replace function settle_bet(p_code text, p_bet bigint, p_win int) returns void language plpgsql security definer set search_path=public as $$
declare b bets%rowtype; e entries%rowtype; pay int; bd int:=0;
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
    bd:=bd+e.stake-pay;
  end loop;
  update bank set balance=balance+bd;
  if bd<>0 then insert into ledger(player_id,delta,reason,bet_id) values(null,bd,'Bank: '||b.title,p_bet); end if;
  update bets set status='settled',winning=p_win where id=p_bet;
end $$;

create or replace function void_bet(p_code text, p_bet bigint) returns void language plpgsql security definer set search_path=public as $$
declare b bets%rowtype; e entries%rowtype;
begin perform need(p_code,'helper');
  select * into b from bets where id=p_bet for update;
  if b.status in('settled','void') then raise exception 'Already closed'; end if;
  for e in select * from entries where bet_id=p_bet loop
    update players set balance=balance+e.stake where id=e.player_id;
    update entries set payout=e.stake where id=e.id;
    insert into ledger(player_id,delta,reason,bet_id) values(e.player_id,e.stake,'Refund: '||b.title,p_bet);
  end loop;
  update bets set status='void' where id=p_bet;
end $$;

-- Host-only undo for a wrongly settled bet: reverses payouts + bank, puts the bet back to locked.
create or replace function reopen_bet(p_code text, p_bet bigint) returns void language plpgsql security definer set search_path=public as $$
declare e entries%rowtype; bd int:=0;
begin perform need(p_code,'super');
  if (select status from bets where id=p_bet)<>'settled' then raise exception 'Not settled'; end if;
  for e in select * from entries where bet_id=p_bet loop
    if coalesce(e.payout,0)>0 then
      update players set balance=balance-e.payout where id=e.player_id;
      insert into ledger(player_id,delta,reason,bet_id) values(e.player_id,-e.payout,'Result reversed',p_bet);
    end if;
    bd:=bd+e.stake-coalesce(e.payout,0);
  end loop;
  update bank set balance=balance-bd;
  if bd<>0 then insert into ledger(player_id,delta,reason,bet_id) values(null,-bd,'Bank: result reversed',p_bet); end if;
  update entries set payout=null where bet_id=p_bet;
  update bets set status='locked',winning=null where id=p_bet;
end $$;

alter publication supabase_realtime add table players, bank, bets, entries, ledger;