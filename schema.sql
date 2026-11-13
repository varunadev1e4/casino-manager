-- PARTY BANK schema. Run once in Supabase > SQL Editor.
-- Also enable: Authentication > Providers > Anonymous sign-ins.

create table settings(key text primary key, value text);
insert into settings values('super_code','ningi-party-2026'),('start_tokens','1000');
-- CHANGE the host code before the party:
-- update settings set value='your-secret' where key='super_code';

create table profiles(id uuid primary key, name text unique not null,
  role text not null default 'member' check(role in('member','admin','super')),
  balance int not null default 0, created_at timestamptz default now());
create table bank(id int primary key default 1 check(id=1), balance int not null);
insert into bank values(1,10000);
create table bets(id bigserial primary key, game text, title text not null,
  mode text not null check(mode in('bank','pool')), options jsonb not null,
  status text not null default 'open' check(status in('open','locked','settled','void')),
  winning int, created_by uuid, created_at timestamptz default now());
create table entries(id bigserial primary key, bet_id bigint references bets on delete cascade,
  player_id uuid references profiles, opt int not null, stake int not null check(stake>0),
  odds numeric not null default 1, payout int, placed_by uuid, created_at timestamptz default now());
create table ledger(id bigserial primary key, player_id uuid, delta int not null,
  reason text, bet_id bigint, staff_id uuid, created_at timestamptz default now());

-- Read-only for clients. All writes go through the functions below.
alter table settings enable row level security;
alter table profiles enable row level security;
alter table bank enable row level security;
alter table bets enable row level security;
alter table entries enable row level security;
alter table ledger enable row level security;

create function need(lvl text) returns void language plpgsql security definer set search_path=public as $$
declare r text; begin
  select role into r from profiles where id=auth.uid();
  if r is null or (lvl='super' and r<>'super') or (lvl='staff' and r='member') then raise exception 'Not allowed'; end if;
end $$;
create function is_staff() returns boolean language sql security definer stable set search_path=public as $$
  select exists(select 1 from profiles where id=auth.uid() and role in('admin','super')) $$;

create policy r on profiles for select to authenticated using(true);
create policy r on bank for select to authenticated using(true);
create policy r on bets for select to authenticated using(true);
create policy r on entries for select to authenticated using(true);
create policy r on ledger for select to authenticated using(player_id=auth.uid() or is_staff());

create function join_party(p_name text) returns void language plpgsql security definer set search_path=public as $$
declare t int; begin
  if exists(select 1 from profiles where id=auth.uid()) then return; end if;
  if length(trim(p_name))<1 then raise exception 'Name required'; end if;
  select value::int into t from settings where key='start_tokens';
  insert into profiles(id,name,balance) values(auth.uid(),trim(p_name),t);
  insert into ledger(player_id,delta,reason) values(auth.uid(),t,'Welcome tokens');
end $$;

create function claim_super(p_code text) returns void language plpgsql security definer set search_path=public as $$
begin
  if p_code is distinct from (select value from settings where key='super_code') then raise exception 'Wrong code'; end if;
  update profiles set role='super' where id=auth.uid();
end $$;

create function set_role(p_player uuid, p_role text) returns void language plpgsql security definer set search_path=public as $$
begin perform need('super');
  if p_role not in('member','admin') then raise exception 'bad role'; end if;
  update profiles set role=p_role where id=p_player and role<>'super';
end $$;

create function adjust(p_player uuid, p_delta int, p_reason text) returns void language plpgsql security definer set search_path=public as $$
begin perform need('super');
  if p_player is null then update bank set balance=balance+p_delta;
  else update profiles set balance=balance+p_delta where id=p_player; end if;
  insert into ledger(player_id,delta,reason,staff_id) values(p_player,p_delta,coalesce(nullif(p_reason,''),'Host adjustment'),auth.uid());
end $$;

create function create_bet(p_game text, p_title text, p_mode text, p_options jsonb) returns void language plpgsql security definer set search_path=public as $$
begin perform need('staff');
  if jsonb_array_length(p_options)<2 then raise exception 'Need 2+ options'; end if;
  insert into bets(game,title,mode,options,created_by) values(p_game,p_title,p_mode,p_options,auth.uid());
end $$;

create function set_status(p_bet bigint, p_status text) returns void language plpgsql security definer set search_path=public as $$
begin perform need('staff');
  if p_status not in('open','locked') then raise exception 'bad status'; end if;
  update bets set status=p_status where id=p_bet and status in('open','locked');
end $$;

create function place_entry(p_bet bigint, p_player uuid, p_opt int, p_stake int) returns void language plpgsql security definer set search_path=public as $$
declare b bets%rowtype; bal int; o numeric;
begin perform need('staff');
  select * into b from bets where id=p_bet for update;
  if b.status<>'open' then raise exception 'Betting is closed'; end if;
  if p_opt<0 or p_opt>=jsonb_array_length(b.options) then raise exception 'bad option'; end if;
  select balance into bal from profiles where id=p_player for update;
  if p_stake<=0 or p_stake>bal then raise exception 'Stake must be 1..% tokens', bal; end if;
  o:=greatest(coalesce((b.options->p_opt->>'odds')::numeric,1),1);
  update profiles set balance=balance-p_stake where id=p_player;
  insert into entries(bet_id,player_id,opt,stake,odds,placed_by) values(p_bet,p_player,p_opt,p_stake,o,auth.uid());
  insert into ledger(player_id,delta,reason,bet_id,staff_id) values(p_player,-p_stake,'Bet: '||b.title,p_bet,auth.uid());
end $$;

create function cancel_entry(p_entry bigint) returns void language plpgsql security definer set search_path=public as $$
declare e entries%rowtype; b bets%rowtype;
begin perform need('staff');
  select * into e from entries where id=p_entry; select * into b from bets where id=e.bet_id;
  if b.status<>'open' then raise exception 'Betting is closed'; end if;
  update profiles set balance=balance+e.stake where id=e.player_id;
  insert into ledger(player_id,delta,reason,bet_id,staff_id) values(e.player_id,e.stake,'Bet cancelled: '||b.title,b.id,auth.uid());
  delete from entries where id=p_entry;
end $$;

create function settle_bet(p_bet bigint, p_win int) returns void language plpgsql security definer set search_path=public as $$
declare b bets%rowtype; e entries%rowtype; tot int; wt int; pay int; bd int:=0;
begin perform need('staff');
  select * into b from bets where id=p_bet for update;
  if b.status in('settled','void') then raise exception 'Already closed'; end if;
  if p_win<0 or p_win>=jsonb_array_length(b.options) then raise exception 'bad option'; end if;
  select coalesce(sum(stake),0), coalesce(sum(stake) filter(where opt=p_win),0) into tot,wt from entries where bet_id=p_bet;
  for e in select * from entries where bet_id=p_bet loop
    if b.mode='bank' then pay:=case when e.opt=p_win then floor(e.stake*e.odds)::int else 0 end;
    elsif wt=0 then pay:=e.stake;
    else pay:=case when e.opt=p_win then floor(e.stake::numeric*tot/wt)::int else 0 end; end if;
    update entries set payout=pay where id=e.id;
    if pay>0 then
      update profiles set balance=balance+pay where id=e.player_id;
      insert into ledger(player_id,delta,reason,bet_id,staff_id) values(e.player_id,pay,case when b.mode='pool' and wt=0 then 'Refund: ' else 'Won: ' end||b.title,p_bet,auth.uid());
    end if;
    bd:=bd+e.stake-pay;
  end loop;
  update bank set balance=balance+bd;
  if bd<>0 then insert into ledger(player_id,delta,reason,bet_id,staff_id) values(null,bd,'Bank: '||b.title,p_bet,auth.uid()); end if;
  update bets set status='settled',winning=p_win where id=p_bet;
end $$;

create function void_bet(p_bet bigint) returns void language plpgsql security definer set search_path=public as $$
declare b bets%rowtype; e entries%rowtype;
begin perform need('staff');
  select * into b from bets where id=p_bet for update;
  if b.status in('settled','void') then raise exception 'Already closed'; end if;
  for e in select * from entries where bet_id=p_bet loop
    update profiles set balance=balance+e.stake where id=e.player_id;
    update entries set payout=e.stake where id=e.id;
    insert into ledger(player_id,delta,reason,bet_id,staff_id) values(e.player_id,e.stake,'Refund: '||b.title,p_bet,auth.uid());
  end loop;
  update bets set status='void' where id=p_bet;
end $$;

-- Super admin undo for a wrongly settled bet: reverses all payouts and the bank, re-locks the bet.
create function reopen_bet(p_bet bigint) returns void language plpgsql security definer set search_path=public as $$
declare e entries%rowtype; bd int:=0;
begin perform need('super');
  if (select status from bets where id=p_bet)<>'settled' then raise exception 'Not settled'; end if;
  for e in select * from entries where bet_id=p_bet loop
    if coalesce(e.payout,0)>0 then
      update profiles set balance=balance-e.payout where id=e.player_id;
      insert into ledger(player_id,delta,reason,bet_id,staff_id) values(e.player_id,-e.payout,'Result reversed',p_bet,auth.uid());
    end if;
    bd:=bd+e.stake-coalesce(e.payout,0);
  end loop;
  update bank set balance=balance-bd;
  if bd<>0 then insert into ledger(player_id,delta,reason,bet_id,staff_id) values(null,-bd,'Bank: result reversed',p_bet,auth.uid()); end if;
  update entries set payout=null where bet_id=p_bet;
  update bets set status='locked',winning=null where id=p_bet;
end $$;

alter publication supabase_realtime add table profiles, bank, bets, entries, ledger;
