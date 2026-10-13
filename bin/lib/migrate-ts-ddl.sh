#!/bin/bash
# bin/lib/migrate-ts-ddl.sh — the literal SQL inside a scripts/migrate-*.ts
# migration (BH-4924, BH-4920.1), so bin/check-migration-appliable.sh can lint a
# .ts migration with the SAME case block it uses for .sql.
#
# usage: . bin/lib/migrate-ts-ddl.sh; mtd_extract <file>
#   rc 2  the file is missing or unreadable (nothing printed)
#   rc 0  one line per statement, in file order, or one `COMPUTED <reason>` line
#         per call site whose SQL is not a plain literal
#
# What it reads, after stripping // and /* */ comments (a string literal is
# matched first and kept verbatim, so a "https://x//y" is not cut; a /…/ regex
# literal is blanked first, so a quote inside it cannot desync the strip):
#   - the FIRST argument of .execute( .executeMultiple( $executeRawUnsafe(
#     db.run( — and, so they cannot slip past, .batch( .migrate( $executeRaw(
#     $queryRawUnsafe( $queryRaw( db.exec( — when it is a '…', "…" or `…`
#     literal followed by `,` or `)`;
#   - the body of a $executeRaw`…`, $queryRaw`…` or sql`…` tagged template.
# Each literal is unescaped, newlines become spaces, and it is split on `;`.
#
# COMPUTED fails closed. The classifier FLAGs every COMPUTED line, because SQL
# this lint cannot read is SQL nobody checked before an irreversible prod apply:
#   template interpolation          a backtick body holding ${
#   string concatenation            a literal followed by +
#   non-literal expression          a literal followed by anything else
#   non-literal first argument      an identifier, { sql: … }, an array
#                                   (.batch([…]), .migrate([…])), an empty call
#   ORM write <op>()                .update( .updateMany( .delete( .deleteMany(
#                                   .upsert( .create( .createMany( .insert(
#   SQL literal outside a           any other literal that reads as write SQL
#     recognised call site          (DELETE FROM, DROP TABLE, UPDATE … SET,
#                                   INSERT INTO, ALTER TABLE, CREATE TABLE,
#                                   PRAGMA, …), so a sink this list never names
#                                   is a FLAG, not a silent pass
#   no literal SQL found            none of the above in the whole file, so a
#                                   .ts that writes some other way never
#                                   lints as "0 statements, all clear"
# Known limit: the regex-literal test is lexical (a / after an operator, `(`,
# `,`, `return`…). A regex in a spot it does not recognise, holding a quote,
# can still desync the comment strip; a template body holding a backtick
# inside ${…} is the same. Both are shapes no migrate-*.ts here uses.
# A false flag costs one human merge; a false pass costs a prod write nobody
# read.

read -r -d '' __MTD_PL <<'PL' || true
my $s = do { local $/; <> };
$s = "" unless defined $s;
my $lit = qr{"(?:\\.|[^"\\])*+"|'(?:\\.|[^'\\])*+'|`(?:\\.|[^`\\])*+`}s;
# A regex literal (/…/ after an operator, `(`, `,`, `return`…) becomes " /re/ "
# so a quote inside it cannot desync the string matcher and turn a real /* */
# span into a "comment" that swallows a live call.
my $re = qr{/(?![/*])(?:\\.|\[(?:\\.|[^\]\\\n])*\]|[^/\\\n\[])+/[A-Za-z]*};
$s =~ s{($lit)|((?:^|[=(,:\[!&|?{};+\-*%<>~^]|\breturn|\btypeof|\bcase)[ \t]*)($re)|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : defined $2 ? "$2 /re/ " : " "}gmse;
my $bal; $bal = qr{\((?:[^()"'`]++|$lit|(??{$bal}))*+\)}s;
my (@out, %used, @cover);
# cover <open-paren offset>: a call that already flagged COMPUTED owns the
# literals in its argument list, so the backstop below does not repeat them.
sub cover {
  my $o = shift;
  if (substr($s, $o) =~ /\A$bal/) { push @cover, [$o, $o + $+[0]] } else { push @cover, [$o, length $s] }
}
sub stmts {
  my $b = shift;
  $b =~ s/\\(["'`])/$1/g;
  $b =~ s/\\[ntr]/ /g;
  $b =~ s/[\r\n]/ /g;
  for my $p (split /;/, $b) {
    $p =~ s/\s+/ /g; $p =~ s/^ //; $p =~ s/ $//;
    push @out, $p if length $p;
  }
}
sub body {
  my ($b, $tpl) = @_;
  if ($tpl && $b =~ /\$\{/) { push @out, "COMPUTED template interpolation" } else { stmts($b) }
}
while ($s =~ /(?<call>\.executeMultiple|\.execute|\.batch|\.migrate|\$executeRawUnsafe|\$executeRaw|\$queryRawUnsafe|\$queryRaw|\bdb\.run|\bdb\.exec)\s*\(|(?<tag>\$executeRaw|\$queryRaw|\bsql)\s*`|\.(?<orm>updateMany|update|deleteMany|delete|upsert|createMany|create|insert)\s*\(/g) {
  if (defined $+{orm}) { push @out, "COMPUTED ORM write $+{orm}()"; next }
  if (defined $+{tag}) {
    pos($s) = pos($s) - 1;
    $used{pos($s)} = 1;
    if ($s =~ /\G`((?:\\.|[^`\\])*+)`/gcs) { body($1, 1) }
    else { push @out, "COMPUTED non-literal expression"; last }
    next;
  }
  my $p = pos($s);
  # .execute(sql`…`): the tag scan reads the template on the next pass.
  if ($s =~ /\G\s*(?:\w+\.)?sql\s*`/gc) { pos($s) = $p; next }
  if ($s =~ /\G\s*($lit)/gc) {
    my $l = $1;
    $used{$-[1]} = 1;
    if ($s =~ /\G(?=\s*[,)])/gc) { body(substr($l, 1, -1), substr($l, 0, 1) eq "`") }
    elsif ($s =~ /\G(?=\s*\+)/gc) { push @out, "COMPUTED string concatenation"; cover($p - 1) }
    else { push @out, "COMPUTED non-literal expression"; cover($p - 1) }
    next;
  }
  push @out, "COMPUTED non-literal first argument";
  cover($p - 1);
}
# Backstop: a literal that reads as write SQL but no recognised call consumed
# (a $queryRawUnsafe-like sink this list never named, a const handed to a
# helper) is COMPUTED, so an unknown sink is a FLAG and never a silent pass.
my $w = qr{\b(?:DELETE\s+FROM|DROP\s+(?:TABLE|INDEX|VIEW|TRIGGER|COLUMN|SCHEMA|DATABASE)|UPDATE\s+(?:OR\s+\w+\s+)?\S.*?\bSET\b|INSERT\s+(?:OR\s+\w+\s+)?INTO|REPLACE\s+INTO|ALTER\s+(?:TABLE|TYPE)|CREATE\s+(?:UNIQUE\s+|VIRTUAL\s+|TEMP(?:ORARY)?\s+)?(?:TABLE|INDEX|VIEW|TRIGGER|FUNCTION|EXTENSION)|TRUNCATE\b|PRAGMA\s+\w|GRANT\s|REVOKE\s|ATTACH\s|VACUUM\b)}is;
while ($s =~ /($lit)/g) {
  my ($a, $l) = ($-[1], $1);
  next if $used{$a} || grep { $a > $_->[0] && $a < $_->[1] } @cover;
  push @out, "COMPUTED SQL literal outside a recognised call site" if $l =~ $w;
}
push @out, "COMPUTED no literal SQL found" unless @out;
print "$_\n" for @out;
PL

mtd_extract() {
  local f="${1:-}"
  [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 2
  perl -e "$__MTD_PL" "$f" || return 2
}
