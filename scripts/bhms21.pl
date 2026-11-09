#!/usr/bin/env perl
# 21-sonli BHMS (lex.uz/docs/-7282737) sahifasini tahlil qiladi.
#
#   perl scripts/bhms21.pl parse  <sahifa.html>              -> JSON snapshot (stdout)
#   perl scripts/bhms21.pl check  [--fetch] <snapshot.json> <data.json> <report.md>
#
# "parse": hujjat matnini elementlarga ajratadi, 1-ilovadagi hisobvaraqlar rejasini (kod, nom, tur)
#          va 2-ilova (yo'riqnoma) bandlarini (band raqami -> matn, jadvallar bilan) chiqaradi.
# "check": lex.uz'dagi amaldagi tahrirni saqlangan snapshot bilan solishtiradi.
#          - schot nomi o'zgargan bo'lsa: data.json'da nomni avtomatik yangilaydi;
#          - schot rejadan chiqarilgan bo'lsa: shu schot qatnashgan savollarni o'yindan olib tashlaydi;
#          - yangi schot yoki band matni o'zgargan bo'lsa: ta'sirlangan savollar ro'yxatini hisobotga yozadi;
#          - snapshot'ni yangi tahrirga yangilaydi.
#          Chiqish kodi: 0 — o'zgarish yo'q, 10 — o'zgarish bor (hisobot yozildi), boshqasi — xato.
use strict;
use warnings;
use utf8;
use JSON::PP;
use Digest::MD5 qw(md5_hex);
use Encode qw(encode_utf8 decode_utf8);

binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';

my $SOURCE = 'https://lex.uz/uz/docs/-7282737';
my $UA = 'mmoliya.uz-bhms-checker/1.0 (+https://mmoliya.uz)';
my $JSON = JSON::PP->new->utf8->canonical->pretty;

sub slurp_bytes { my $f = shift; open(my $h, '<:raw', $f) or die "open $f: $!\n"; local $/; my $t = <$h>; close $h; $t =~ s/^\xEF\xBB\xBF//; $t }
sub spew_bytes { my ($f, $t) = @_; open(my $h, '>:raw', $f) or die "write $f: $!\n"; print $h $t; close $h }

my %ENT = (nbsp => ' ', laquo => '«', raquo => '»', ldquo => '“', rdquo => '”', bdquo => '„', quot => '"', amp => '&',
           lt => '<', gt => '>', mdash => '—', ndash => '–', apos => "'", rsquo => '’', lsquo => '‘', hellip => '…', shy => '');
sub text_of {
    my $h = shift;
    $h =~ s/<sup>\s*(\d+)\s*<\/sup>/-$1/g;          # 73<sup>1</sup> -> 73-1
    $h =~ s/<br\s*\/?>/ /gi;
    $h =~ s/<[^>]+>//g;
    $h =~ s/&#(\d+);/chr($1)/ge;
    $h =~ s/&#x([0-9a-f]+);/chr(hex $1)/gie;
    $h =~ s/&([a-z]+);/exists $ENT{$1} ? $ENT{$1} : "&$1;"/ge;
    $h =~ s/[\x{a0}\s]+/ /g;
    $h =~ s/^\s+|\s+$//g;
    return $h;
}

# Hujjat elementlari: <div class="KLASS lx_elem" ...> ... <div name="ID" id="ID">MAZMUN</div></div>
sub elements {
    my $html = shift;
    my $start = index($html, 'id="divCont"');
    $html = substr($html, $start) if $start >= 0;
    my @parts = split /(?=<div class="[A-Z0-9_]+ (?:lx_elem|lx_no_select)")/, $html;
    my @out;
    for my $p (@parts) {
        next unless $p =~ /^<div class="([A-Z0-9_]+) (lx_elem|lx_no_select)"/;
        my ($cls, $kind) = ($1, $2);
        next if $kind eq 'lx_no_select';           # izohlar, "tahririda" belgilari, havolalar
        # Mazmun ichida div yo'q (matn — span'lar, jadval — table): birinchi </div> gacha olinadi,
        # shunda oxirgi elementga sahifaning skriptlari qo'shilib ketmaydi
        next unless $p =~ /<div name="-?\d+" id="-?\d+">(.*?)<\/div>/s;
        my $body = $1;
        if ($body =~ /<table/i) {
            my @rows;
            for my $tr ($body =~ /<tr[^>]*>(.*?)<\/tr>/sgi) {
                my @cells = map { text_of($_) } ($tr =~ /<td[^>]*>(.*?)<\/td>/sgi);
                push @rows, \@cells if grep { $_ ne '' } @cells;
            }
            push @out, { cls => $cls, table => \@rows };
        } else {
            my $t = text_of($body);
            push @out, { cls => $cls, text => $t } if $t ne '';
        }
    }
    return @out;
}

sub parse_html {
    my $html = decode_utf8(shift);
    my @el = elements($html);
    my (@accounts, %bands, @order, $zone, $band, %seen);
    $zone = 'order';
    for my $e (@el) {
        my $t = $e->{text} // '';
        # Ilovalar sarlavhasi alohida ACT_FORM elementida: "HISOBVARAQLAR REJASI" (1-ilova), "YOʻRIQNOMA" (2-ilova)
        # Boshqa sarlavha (masalan, buyruqning 2-ilovasi "ROʻYXATI" — kuchini yo'qotgan hujjatlar) — hisobga olinmaydi
        $zone = 'other' if $e->{cls} =~ /^APPL_BANNER/;    # har bir ilova shu banner bilan boshlanadi
        if ($e->{cls} eq 'ACT_FORM') {
            $zone = $t =~ /^HISOBVARAQLAR REJASI$/ ? 'plan'
                  : $t =~ /^YO[ʻ'‘’`]?RIQNOMA$/    ? 'guide'
                  : 'other';
        }
        if ($zone eq 'plan' && $e->{table}) {
            for my $r (@{ $e->{table} }) {
                my @c = @$r;
                my ($i) = grep { $c[$_] =~ /^\d{3,4}$/ } 0 .. $#c;
                next unless defined $i;
                my $code = $c[$i];
                next if $seen{$code}++;
                my $name = $c[$i + 1] // '';
                my $type = $c[$i + 2] // '';
                $type = '' unless $type =~ /^(A|P|KA|KP|BT|A\/P)$/;
                push @accounts, { code => $code, name => $name, type => $type };
            }
            next;
        }
        next unless $zone eq 'guide';
        # Band boshi: "34. ...", "73-1. ..." (73¹). Manbada nuqtasiz yozilgan band (masalan, "67 Asosiy ...")
        # faqat navbatdagi raqam bo'lsa qabul qilinadi — "4010 “...”" kabi qatorlar band emas.
        my ($num, $dot) = $e->{table} ? () : ($t =~ /^(\d{1,3}(?:-\d+)?)(\.?)\s/);
        my $prev = defined $band && $band =~ /^(\d+)/ ? $1 : 0;
        if (defined $num && ($dot || $num eq $prev + 1)) {
            $band = $num;
            push @order, $band unless exists $bands{$band};
            $bands{$band} = $t;
            next;
        }
        next unless defined $band;
        my $add = $e->{table} ? join("\n", map { join(' | ', @$_) } @{ $e->{table} }) : $t;
        $bands{$band} .= "\n" . $add;
    }
    my @editions = do { my %u; grep { !$u{$_}++ } ($html =~ /lx_date_link"[^>]*>(\d\d\.\d\d\.\d{4})</g) };
    return {
        source   => $SOURCE,
        editions => [ sort { join('', reverse split /\./, $a) cmp join('', reverse split /\./, $b) } @editions ],
        accounts => \@accounts,
        bands    => { map { $_ => { hash => md5_hex(encode_utf8($bands{$_})), text => $bands{$_} } } @order },
        band_order => \@order,
    };
}

# Savolda ishlatilgan band raqamlari: "yoʻriqnoma, 23-band", "374-band", "40- va 41-band"
sub bands_in {
    my $s = shift // '';
    my %b;
    while ($s =~ /(\d+(?:-\d+)?)(?=(?:\s*[-–]?\s*(?:va|,)\s*\d+(?:-\d+)?)*\s*[-–]?\s*band)/g) { $b{$1} = 1 }
    while ($s =~ /(\d+)\s*[-–]\s*band/g) { $b{$1} = 1 }
    return keys %b;
}

# Repoda saqlanadigan snapshot: band matni o'rniga faqat uning izi (hash) — fayl kichik bo'lsin
sub snapshot_of {
    my $s = shift;
    return { %$s, bands => { map { $_ => { hash => $s->{bands}{$_}{hash} } } keys %{ $s->{bands} } } };
}

sub fetch_source {
    my $out = shift;
    my $rc = system('curl', '-sSL', '--max-time', '120', '--retry', '3', '-A', $UA, '-o', $out, $SOURCE);
    die "lex.uz yuklab olinmadi (curl $rc)\n" if $rc != 0 || !-s $out;
}

sub cmd_check {
    my @a = @_;
    my $fetch = 0;
    if (@a && $a[0] eq '--fetch') { $fetch = 1; shift @a }
    my ($snapFile, $dataFile, $reportFile, $htmlFile) = @a;
    die "foydalanish: check [--fetch] snapshot.json data.json report.md [sahifa.html]\n" unless $reportFile;
    $htmlFile //= 'bhms21_current.html';
    fetch_source($htmlFile) if $fetch;
    my $cur = parse_html(slurp_bytes($htmlFile));

    # Himoya: sahifa tuzilishi o'zgargan yoki to'liq yuklanmagan bo'lsa — hech narsani o'zgartirmaymiz
    my $nAcc = scalar @{ $cur->{accounts} };
    my $nBand = scalar @{ $cur->{band_order} };
    die "Sahifa tahlil qilinmadi: $nAcc ta schot, $nBand ta band (kutilgan: 300+ va 400+)\n" if $nAcc < 300 || $nBand < 400;

    # O'yin sahifasi ko'rsatadigan amaldagi tahrir sanasi (data.json -> meta)
    my $data = $JSON->decode(slurp_bytes($dataFile));
    my $edition = $cur->{editions}[-1] // '';
    my $metaChanged = ($data->{meta}{edition} // '') ne $edition || ($data->{meta}{source} // '') ne $SOURCE;
    $data->{meta} = { edition => $edition, source => $SOURCE };
    my $saveData = sub { spew_bytes($dataFile, JSON::PP->new->utf8->canonical->encode($data)) };

    my $old = -e $snapFile ? $JSON->decode(slurp_bytes($snapFile)) : undef;
    unless ($old) {
        spew_bytes($snapFile, $JSON->encode(snapshot_of($cur)));
        $saveData->() if $metaChanged;
        print "Snapshot yaratildi: $nAcc schot, $nBand band, tahrirlar: @{ $cur->{editions} }\n";
        return 0;
    }

    # Nomsiz (zaxira) kodlar o'yinda schot hisoblanmaydi: nom bo'shab qolsa — chiqarilgan, nom paydo bo'lsa — yangi
    my %oa = map { $_->{code} => $_ } grep { $_->{name} ne '' } @{ $old->{accounts} };
    my %ca = map { $_->{code} => $_ } grep { $_->{name} ne '' } @{ $cur->{accounts} };
    my (@renamed, @removed, @added, @bandChanged, @bandAdded, @bandRemoved);
    for my $c (sort keys %oa) {
        if (!$ca{$c}) { push @removed, $c; next }
        push @renamed, [$c, $oa{$c}{name}, $ca{$c}{name}] if $oa{$c}{name} ne $ca{$c}{name};
    }
    for my $c (sort keys %ca) { push @added, $c unless $oa{$c} }
    for my $b (@{ $cur->{band_order} }) {
        if (!$old->{bands}{$b}) { push @bandAdded, $b; next }
        push @bandChanged, $b if $old->{bands}{$b}{hash} ne $cur->{bands}{$b}{hash};
    }
    for my $b (@{ $old->{band_order} }) { push @bandRemoved, $b unless $cur->{bands}{$b} }
    my %oldEd = map { $_ => 1 } @{ $old->{editions} || [] };
    my @newEditions = grep { !$oldEd{$_} } @{ $cur->{editions} };

    my $changed = @renamed || @removed || @added || @bandChanged || @bandAdded || @bandRemoved || @newEditions;
    unless ($changed) {
        $saveData->() if $metaChanged;
        print "BHMS 21 oʻzgarmagan (tahrirlar: @{ $cur->{editions} })\n";
        return 0;
    }

    # data.json: nomlarni yangilash, chiqarilgan schotlar qatnashgan savollarni olib tashlash
    my %rm = map { $_ => 1 } grep { length($_) == 4 || length($_) == 3 } @removed;
    my %newName = map { $_->[0] => $_->[2] } @renamed;
    my %dataAcc = map { $_->{code} => $_ } @{ $data->{accounts} };
    $dataAcc{$_}{name} = $newName{$_} for grep { $dataAcc{$_} && $newName{$_} ne '' } keys %newName;
    my @droppedQ;
    my %touch = map { $_ => 1 } (@bandChanged, @bandAdded, @bandRemoved);
    my (@reviewQ, %reviewWhy);
    my @keep;
    for my $q (@{ $data->{questions} }) {
        my @codes = grep { defined && $_ ne '' && $_ ne '-' } ($q->{answer}, $q->{dt}, $q->{kt}, @{ $q->{options} || [] });
        if (grep { $rm{$_} } @codes) { push @droppedQ, $q->{id}; next }
        push @keep, $q;
        my @why;
        push @why, map { "schot $_ nomi" } grep { $newName{$_} } ($q->{answer}, $q->{dt} // (), $q->{kt} // ());
        push @why, map { "$_-band" } grep { $touch{$_} } bands_in($q->{explain});
        my %u;
        @why = grep { !$u{$_}++ } @why;
        if (@why) { push @reviewQ, $q->{id}; $reviewWhy{ $q->{id} } = join(', ', @why) }
    }
    $data->{questions} = \@keep;
    $data->{accounts} = [ grep { !$rm{ $_->{code} } } @{ $data->{accounts} } ];
    $saveData->();

    # Hisobot
    my @r;
    push @r, "# 21-sonli BHMS yangilandi", '';
    push @r, "Manba: $SOURCE", "Amaldagi tahrirlar: " . join(', ', @{ $cur->{editions} }), '';
    push @r, "**Yangi tahrir:** " . join(', ', @newEditions), '' if @newEditions;
    push @r, "Oʻyin maʼlumotlari (oyin/data.json) avtomatik moslashtirildi: schot nomlari yangilandi, rejadan chiqarilgan schotlar boʻyicha savollar olib tashlandi. Quyidagi savollarni yangi matn asosida koʻrib chiqish kerak.", '';
    if (@renamed) { push @r, "## Nomi oʻzgargan schotlar (avtomatik yangilandi)", map({ "- **$_->[0]**: «$_->[1]» → «$_->[2]»" } @renamed), '' }
    if (@removed) { push @r, "## Rejadan chiqarilgan schotlar", map({ "- **$_** «$oa{$_}{name}»" } @removed), '' }
    if (@droppedQ) { push @r, "## Oʻyindan olib tashlangan savollar (" . scalar(@droppedQ) . ")", join(', ', @droppedQ), '' }
    if (@added) { push @r, "## Yangi schotlar (hali savoli yoʻq)", map({ "- **$_** «$ca{$_}{name}»" } @added), '' }
    if (@bandChanged || @bandAdded || @bandRemoved) {
        push @r, "## Oʻzgargan bandlar";
        push @r, map({ "- $_-band — matni oʻzgardi" } @bandChanged), map({ "- $_-band — yangi" } @bandAdded), map({ "- $_-band — chiqarildi" } @bandRemoved), '';
        for my $b (@bandChanged, @bandAdded) {
            my $t = $cur->{bands}{$b}{text};
            $t = substr($t, 0, 1500) . ' …' if length $t > 1500;
            push @r, "<details><summary>$b-band — yangi matn</summary>", '', '```', $t, '```', '</details>', '';
        }
    }
    if (@reviewQ) { push @r, "## Koʻrib chiqilishi kerak boʻlgan savollar (" . scalar(@reviewQ) . ")", map({ "- `$_` — $reviewWhy{$_}" } @reviewQ), '' }
    spew_bytes($reportFile, encode_utf8(join("\n", @r) . "\n"));
    spew_bytes($snapFile, $JSON->encode(snapshot_of($cur)));
    print "Oʻzgarishlar topildi: ", scalar(@renamed), " nom, ", scalar(@removed), " chiqarilgan, ", scalar(@added), " yangi schot; ",
          scalar(@bandChanged) + scalar(@bandAdded) + scalar(@bandRemoved), " band; ", scalar(@droppedQ), " savol olib tashlandi; ", scalar(@reviewQ), " savol koʻrib chiqilishi kerak\n";
    return 10;
}

my $cmd = shift @ARGV // '';
if ($cmd eq 'parse') {
    my $f = shift @ARGV or die "foydalanish: parse sahifa.html\n";
    print STDOUT decode_utf8($JSON->encode(parse_html(slurp_bytes($f))));
    exit 0;
} elsif ($cmd eq 'dump') {
    # Nosozlikni tekshirish uchun: elementlar ro'yxati (klass + matn boshi / jadvalning birinchi qatorlari)
    my ($f, $from, $n) = @ARGV;
    my @el = elements(decode_utf8(slurp_bytes($f)));
    $from //= 0; $n //= 60;
    for my $i ($from .. $from + $n - 1) {
        last if $i > $#el;
        my $e = $el[$i];
        my $s = $e->{table} ? 'TABLE[' . scalar(@{ $e->{table} }) . '] ' . join(' || ', map { join(' | ', @$_) } @{ $e->{table} }[0 .. 2]) : $e->{text};
        printf "%5d %-24s %s\n", $i, $e->{cls}, substr($s, 0, 160);
    }
    exit 0;
} elsif ($cmd eq 'check') {
    exit cmd_check(@ARGV);
} else {
    die "buyruq: parse | check\n";
}
