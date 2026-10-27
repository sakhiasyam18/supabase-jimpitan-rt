-- =====================================================================
-- JIMPITAN RT 23 RW 6 -- SQL FINAL (Supabase / Postgres)
-- Jalankan SEKALI di Supabase > SQL Editor, dari atas sampai bawah.
-- Aman dijalankan ulang (idempotent).
-- Tabel yang sudah ada: warga, akun_petugas, jadwal, setoran, pengaturan.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. BERSIHKAN OBJEK LAMA (supaya tidak bentrok dengan versi sebelumnya)
--    Urutan penting: policy dan view dihapus dulu, baru fungsi.
--    Hanya menghapus fungsi/view/policy. Data di tabel TIDAK disentuh.
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select policyname, tablename from pg_policies
    where schemaname = 'public'
      and tablename in ('warga','akun_petugas','jadwal','setoran','pengaturan')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

drop trigger  if exists setoran_catat on public.setoran;
drop view     if exists public.v_saldo_warga;
drop function if exists public.ringkasan_publik();
drop function if exists public.ringkasan_publik(date);          -- versi lama (dengan argumen)
drop function if exists public.is_petugas_aktif();              -- versi lama
drop function if exists public.hitung_jumlah_sabtu(date, date); -- versi lama
drop function if exists public.trg_setoran_catat();
drop function if exists public.is_petugas();
drop function if exists public.sabtu_berikutnya();
drop function if exists public.sabtu_terbaru();
drop function if exists public.hari_ini_wib();


-- ---------------------------------------------------------------------
-- 1. RAPIKAN TABEL (constraint yang kurang)
-- ---------------------------------------------------------------------

-- warga
update public.warga set aktif = true where aktif is null;
alter table public.warga alter column aktif set default true;
alter table public.warga alter column aktif set not null;

alter table public.warga drop constraint if exists warga_blok_no_unik;
alter table public.warga add constraint warga_blok_no_unik unique (blok, no_rumah);

-- akun_petugas
update public.akun_petugas set aktif = true where aktif is null;
alter table public.akun_petugas alter column aktif set default true;
alter table public.akun_petugas alter column aktif set not null;

-- setoran: satu rumah satu setoran per Sabtu, rumah wajib ada
alter table public.setoran alter column warga_id set not null;
alter table public.setoran alter column tanggal set not null;
alter table public.setoran drop constraint if exists setoran_tanggal_warga_unik;
alter table public.setoran add constraint setoran_tanggal_warga_unik unique (tanggal, warga_id);

-- jadwal: dua petugas tidak boleh orang yang sama
alter table public.jadwal drop constraint if exists jadwal_petugas_beda;
alter table public.jadwal add constraint jadwal_petugas_beda
  check (petugas_1 is null or petugas_2 is null or petugas_1 <> petugas_2);

-- pengaturan: nilai wajar
update public.pengaturan set iuran_per_minggu = 2000 where iuran_per_minggu is null;
update public.pengaturan set batas_langganan_nunggak = 3 where batas_langganan_nunggak is null;
alter table public.pengaturan alter column iuran_per_minggu set not null;
alter table public.pengaturan alter column batas_langganan_nunggak set not null;

alter table public.pengaturan drop constraint if exists pengaturan_iuran_positif;
alter table public.pengaturan add constraint pengaturan_iuran_positif check (iuran_per_minggu > 0);

alter table public.pengaturan drop constraint if exists pengaturan_batas_positif;
alter table public.pengaturan add constraint pengaturan_batas_positif check (batas_langganan_nunggak >= 1);

-- Bila tanggal_mulai lama bukan Sabtu (mis. dari skema awal: current_date), geser ke Sabtu berikutnya
update public.pengaturan
set tanggal_mulai = tanggal_mulai + ((6 - extract(isodow from tanggal_mulai)::int + 7) % 7)
where tanggal_mulai is not null and extract(isodow from tanggal_mulai) <> 6;

alter table public.pengaturan drop constraint if exists pengaturan_mulai_sabtu;
alter table public.pengaturan add constraint pengaturan_mulai_sabtu
  check (tanggal_mulai is null or extract(isodow from tanggal_mulai) = 6);

create index if not exists setoran_warga_idx on public.setoran (warga_id);


-- ---------------------------------------------------------------------
-- 2. ISI PENGATURAN (satu baris)
--    GANTI tanggal_mulai bila pengambilan pertama bukan 24 Okt 2026
--    (harus hari Sabtu).
-- ---------------------------------------------------------------------
insert into public.pengaturan (id, iuran_per_minggu, tanggal_mulai, batas_langganan_nunggak)
values (1, 2000, '2026-10-24', 3)
on conflict (id) do update
  set tanggal_mulai = coalesce(public.pengaturan.tanggal_mulai, excluded.tanggal_mulai);


-- ---------------------------------------------------------------------
-- 3. FUNGSI TANGGAL (zona waktu WIB)
-- ---------------------------------------------------------------------
create or replace function public.hari_ini_wib()
returns date language sql stable as $$
  select (now() at time zone 'Asia/Jakarta')::date
$$;

-- Sabtu terbaru yang sudah tiba (hari ini kalau hari ini Sabtu). Dipakai untuk rekap dan input setoran.
create or replace function public.sabtu_terbaru()
returns date language sql stable as $$
  select public.hari_ini_wib() - ((extract(isodow from public.hari_ini_wib())::int + 1) % 7)
$$;

-- Sabtu berikutnya (hari ini kalau hari ini Sabtu). Dipakai untuk "petugas jaga".
create or replace function public.sabtu_berikutnya()
returns date language sql stable as $$
  select public.hari_ini_wib() + ((6 - extract(isodow from public.hari_ini_wib())::int + 7) % 7)
$$;


-- ---------------------------------------------------------------------
-- 4. PEMERIKSA PETUGAS
-- ---------------------------------------------------------------------
create or replace function public.is_petugas()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.akun_petugas
    where user_id = auth.uid() and aktif
  )
$$;

revoke all on function public.is_petugas() from public, anon, authenticated;
grant execute on function public.is_petugas() to authenticated;


-- ---------------------------------------------------------------------
-- 5. TRIGGER SETORAN: catat siapa dan kapan, tolak rumah tidak aktif
-- ---------------------------------------------------------------------
create or replace function public.trg_setoran_catat()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if not exists (select 1 from public.warga where id = new.warga_id and aktif) then
      raise exception 'RUMAH_TIDAK_AKTIF: Rumah tidak aktif atau tidak ditemukan.';
    end if;
  end if;
  new.dicatat_oleh := auth.uid();
  new.dicatat_pada := now();
  return new;
end;
$$;

drop trigger if exists setoran_catat on public.setoran;
create trigger setoran_catat
  before insert or update on public.setoran
  for each row execute function public.trg_setoran_catat();


-- ---------------------------------------------------------------------
-- 6. VIEW SALDO PER RUMAH (satu-satunya sumber hitungan)
--    saldo          = total dibayar - (iuran x jumlah Sabtu sejak tanggal_mulai)
--    minggu_nunggak = jumlah minggu yang masih kurang (0 kalau saldo >= 0)
--    langganan_nunggak = minggu_nunggak >= batas_langganan_nunggak
-- ---------------------------------------------------------------------
drop view if exists public.v_saldo_warga;
create view public.v_saldo_warga
with (security_invoker = true) as
with p as (
  select iuran_per_minggu as iuran,
         batas_langganan_nunggak as batas,
         tanggal_mulai,
         public.sabtu_terbaru() as sabtu
  from public.pengaturan
  where id = 1
),
n as (
  select iuran, batas, sabtu,
         case when tanggal_mulai is not null and sabtu >= tanggal_mulai
              then (sabtu - tanggal_mulai) / 7 + 1
              else 0 end as jumlah_sabtu
  from p
),
bayar as (
  select warga_id, sum(jumlah)::int as total
  from public.setoran
  group by warga_id
),
base as (
  select
    w.id as warga_id,
    w.blok,
    w.no_rumah,
    w.nama,
    w.aktif,
    w.blok || '/' || w.no_rumah || ' · ' || w.nama as label,
    n.sabtu as sabtu_terbaru,
    coalesce(sini.jumlah, 0) as setoran_sabtu_ini,
    (sini.id is not null) as sudah_dicatat_sabtu_ini,
    coalesce(b.total, 0) as dibayar,
    n.iuran * n.jumlah_sabtu as kewajiban,
    coalesce(b.total, 0) - n.iuran * n.jumlah_sabtu as saldo,
    n.iuran,
    n.batas
  from public.warga w
  cross join n
  left join bayar b on b.warga_id = w.id
  left join public.setoran sini
    on sini.warga_id = w.id and sini.tanggal = n.sabtu
),
hitung as (
  select base.*,
         greatest(0, ceil(-base.saldo::numeric / base.iuran))::int as minggu_nunggak
  from base
)
select
  warga_id, blok, no_rumah, nama, aktif, label,
  sabtu_terbaru, setoran_sabtu_ini, sudah_dicatat_sabtu_ini,
  dibayar, kewajiban, saldo,
  minggu_nunggak,
  (minggu_nunggak >= batas) as langganan_nunggak
from hitung;


-- ---------------------------------------------------------------------
-- 7. RINGKASAN PUBLIK (tanpa login, tanpa nama warga, tanpa nominal per rumah)
--    sudah     = rumah aktif dengan saldo >= 0
--    nunggak   = rumah aktif yang kurang >= 2 minggu
--    petugas   = 2 nama jaga di Sabtu berikutnya (atau Sabtu ini)
-- ---------------------------------------------------------------------
create or replace function public.ringkasan_publik()
returns jsonb
language sql stable security definer
set search_path = public
as $$
  with t as (
    select public.sabtu_terbaru() as rekap, public.sabtu_berikutnya() as jaga
  ),
  r as (
    select * from public.v_saldo_warga where aktif
  ),
  per_blok as (
    select blok,
           count(*)::int as total,
           (count(*) filter (where saldo >= 0))::int as sudah,
           (count(*) filter (where minggu_nunggak >= 2))::int as nunggak
    from r
    group by blok
  )
  select jsonb_build_object(
    'sabtu_rekap', (select rekap from t),
    'sabtu_jaga',  (select jaga from t),
    'petugas', coalesce((
        select jsonb_agg(w.nama order by w.nama)
        from public.jadwal j
        join public.warga w on w.id in (j.petugas_1, j.petugas_2)
        where j.tanggal = (select jaga from t)
      ), '[]'::jsonb),
    'terkumpul', coalesce((
        select sum(jumlah) from public.setoran
        where tanggal = (select rekap from t)
      ), 0),
    'sudah_bayar', (select count(*) filter (where saldo >= 0) from r),
    'total_rumah', (select count(*) from r),
    'blok', coalesce((
        select jsonb_agg(to_jsonb(pb) order by pb.blok) from per_blok pb
      ), '[]'::jsonb)
  )
$$;

revoke all on function public.ringkasan_publik() from public, anon, authenticated;
grant execute on function public.ringkasan_publik() to anon, authenticated;


-- ---------------------------------------------------------------------
-- 8. KEAMANAN: RLS + HAK AKSES
-- ---------------------------------------------------------------------

-- Hapus semua policy lama supaya bersih
do $$
declare r record;
begin
  for r in
    select policyname, tablename from pg_policies
    where schemaname = 'public'
      and tablename in ('warga','akun_petugas','jadwal','setoran','pengaturan')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

alter table public.warga        enable row level security;
alter table public.akun_petugas enable row level security;
alter table public.jadwal       enable row level security;
alter table public.setoran      enable row level security;
alter table public.pengaturan   enable row level security;

-- Petugas aktif: baca dan tulis semua data operasional
create policy petugas_semua on public.warga
  for all to authenticated using (public.is_petugas()) with check (public.is_petugas());

create policy petugas_semua on public.jadwal
  for all to authenticated using (public.is_petugas()) with check (public.is_petugas());

create policy petugas_semua on public.setoran
  for all to authenticated using (public.is_petugas()) with check (public.is_petugas());

create policy petugas_semua on public.pengaturan
  for all to authenticated using (public.is_petugas()) with check (public.is_petugas());

-- akun_petugas: petugas boleh MELIHAT (untuk pilihan jadwal), tiap orang boleh melihat barisnya sendiri.
-- Menambah/mengubah akun dilakukan lewat dashboard Supabase.
create policy lihat_akun on public.akun_petugas
  for select to authenticated using (public.is_petugas() or user_id = auth.uid());

-- Pengunjung tanpa login tidak boleh menyentuh tabel apa pun
revoke all on public.warga, public.akun_petugas, public.jadwal,
              public.setoran, public.pengaturan, public.v_saldo_warga from anon;

grant select on public.v_saldo_warga to authenticated;


-- ---------------------------------------------------------------------
-- 9. DATA AWAL: 51 RUMAH (aman diulang, tidak menggandakan)
--    Catatan: "NU MARIJAN" mungkin "NY MARIJAN", konfirmasi ke client.
-- ---------------------------------------------------------------------
insert into public.warga (blok, no_rumah, nama) values
('C0','01','AGUNG'),('C0','04','GHON'),('C0','06','LULUK'),('C0','07','HELMI'),
('C0','08','AGUS'),('C0','11','MAHFUD'),('C0','14','BIANTO'),('C0','16','CUCUK'),
('C0','17','WIDI'),('C0','09','BU YULI'),('C0','18','ANDIK'),('C0','20','BU SRI'),
('C0','19','ROBI'),('C0','21','SUGENG'),('C0','22','ARIF FANDI'),('C0','23','MARSUDI'),
('C0','24','ANGGIT'),('C0','25','EKO YULI'),('C0','26','REDO'),('C0','27','UJIONO'),
('C0','33','MASRURI'),('C0','34','HENDRO'),('C0','36','WIWIN'),('C0','37','DEDI'),
('C0','35','NU MARIJAN'),('C0','30','BU RENI'),('C0','38','ARIF N'),('C0','39','SUTARTO'),
('C0','41','LASIMIN'),
('C1','02','HENDRA K'),('C1','06','TRI ANANTO'),
('C2','01','HENDRA W'),('C2','02','ANWAR'),('C2','06','HUTAPEA'),('C2','07','HERU SURYA'),
('C2','08','SUPARTO'),('C2','09','PUTHUT'),('C2','10','SUMADI'),('C2','05','BU MUHTAROM'),
('C2','12','SUWONDO'),('C2','14','ABDUL QODIR'),('C2','15','IMAN'),('C2','16','BU TOM'),
('C2','17','DAVIT'),('C2','18','SUPARMAN'),('C2','19','BU SOFNI'),('C2','20','BU HERU'),
('C2','22','EKO HARI'),('C2','23','SUKADI'),('C2','04','BU IRA'),('C2','11','BU BERNADUS')
on conflict (blok, no_rumah) do nothing;


-- ---------------------------------------------------------------------
-- 10. TEMPLATE MEMBUAT AKUN PETUGAS (jalankan per petugas, setelah langkah 1 dan 2)
--
-- Langkah A (di dashboard): Authentication > Users > Add user
--   Email    : <nama-kecil-tanpa-spasi>@jimpitan.local   mis. pak.heru@jimpitan.local
--   Password : PIN 6 digit
--   Centang "Auto Confirm User"
--
-- Langkah B (hubungkan ke warga). Hapus tanda komentar dan sesuaikan:
--
-- insert into public.akun_petugas (user_id, warga_id, nama)
-- select u.id, w.id, 'Pak Heru'
-- from auth.users u, public.warga w
-- where u.email = 'pak.heru@jimpitan.local'
--   and w.blok = 'C2' and w.no_rumah = '07';
-- ---------------------------------------------------------------------


-- ---------------------------------------------------------------------
-- 11. PEMERIKSAAN HASIL (jalankan, bandingkan dengan yang diharapkan)
-- ---------------------------------------------------------------------
-- Diharapkan: C0 = 29, C1 = 2, C2 = 20 (total 51)
select blok, count(*) as jumlah_rumah from public.warga group by blok order by blok;

-- Diharapkan: 1 baris dengan tanggal_mulai berhari Sabtu
select * from public.pengaturan;

-- Diharapkan: JSON dengan total_rumah = 51
select public.ringkasan_publik();

-- Diharapkan: semua tabel rowsecurity = true
select tablename, rowsecurity from pg_tables
where schemaname = 'public'
  and tablename in ('warga','akun_petugas','jadwal','setoran','pengaturan');
