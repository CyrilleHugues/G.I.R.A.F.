#! /usr/bin/perl
$| = 1;

package Giraf::Modules::Chan;

use strict;
use warnings;
use DBI;

our $dbh;
our $kernel;
our $irc;
our $botname;

sub init {
	my ( $classe, $ker, $irc_session,$bot_name) = @_;
	$kernel  = $ker;
	$irc     = $irc_session;
	$botname=$bot_name;
	$dbh=DBI->connect("dbi:SQLite:dbname=:memory:","","");
	$dbh->do("BEGIN TRANSACTION;");
	$dbh->do("CREATE TABLE chans (enforce NUMERIC, id INTEGER PRIMARY KEY AUTOINCREMENT , name TEXT);");
	$dbh->do("CREATE TABLE privileges (chan_id NUMERIC, id INTEGER PRIMARY KEY AUTOINCREMENT , privilege_type NUMERIC, user_id NUMERIC);");
	$dbh->do("CREATE TABLE presences (chan_id NUMERIC, id INTEGER PRIMARY KEY AUTOINCREMENT , privilege_type NUMERIC, user_id NUMERIC);");
	$dbh->do("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);");
        $dbh->do("COMMIT;");
}

sub join {
	my ( $class, $nom ) = @_;
	my $sth=$dbh->prepare('INSERT INTO chans (name) VALUES (?)');	
	$sth->execute($nom);
	$kernel->post( $irc => join => $nom );
}

sub add_user {
	my ( $classe, $chan_nom, $user ) = @_;
	my $sth=$dbh->prepare('SELECT COUNT(*) FROM users WHERE name LIKE ?');
	my ($count,$username,$privileges);
	$sth->bind_columns( \$count );
	if ( ($username)= $user =~ /^@(.*)/ ) {
		$sth->execute($username);
		$sth->fetch();
		if($count>0)
		{
		}
		else
		{
			$sth=$dbh->prepare('INSERT INTO users (name) VALUES (?)');
			$sth->execute($username);
		}
		$privileges=8;
	}
	elsif ( ($username) = $user =~ /^\+(.*)/ ) {

		$sth->execute($username);
		$sth->fetch();
		if($count>0)
		{
		}
		else
		{
			$sth=$dbh->prepare('INSERT INTO users (name) VALUES (?)');
			$sth->execute($username);
		}
		$privileges=4;
	}
	else {
		$username=$user;
		$sth->execute($username);
		$sth->fetch();
		if($count>0)
		{
		}
		else
		{
			$sth=$dbh->prepare('INSERT INTO users (name) VALUES (?)');
			$sth->execute($username);
		}
		$privileges=2;
	}
	#Verification des privileges existants pour l'utilisateur sur le chan.
	$sth=$dbh->prepare('SELECT COUNT(*) FROM privileges WHERE user_id = (SELECT id FROM users WHERE name LIKE ?) AND chan_id=(SELECT id FROM chans WHERE name LIKE ?);');
	$sth->bind_columns(\$count);
	$sth->execute($username,$chan_nom);
	if($count==0)
	{
		#L'utilisateur a deja des privileges sur le chan.
		$sth=$dbh->prepare('INSERT INTO privileges (chan_id,user_id,privilege_type) VALUES ((SELECT id FROM chans WHERE name LIKE ?),(SELECT id FROM users WHERE name LIKE ?),?)');
		$sth->execute($chan_nom,$username,$privileges);
	}
	$sth=$dbh->prepare('SELECT COUNT(*) FROM presences WHERE user_id = (SELECT id FROM users WHERE name LIKE ?) AND chan_id=(SELECT id FROM chans WHERE name LIKE ?);');
	$sth->bind_columns(\$count);
	$sth->execute($username,$chan_nom);
	if($count==0)
	{
		$sth=$dbh->prepare('INSERT INTO presences (chan_id,user_id,privilege_type) VALUES ((SELECT id FROM chans WHERE name LIKE ?),(SELECT id FROM users WHERE name LIKE ?),?)');
		$sth->execute($chan_nom,$username,$privileges);
	}
	else
	{
		$sth=$dbh->prepare('UPDATE presences SET privilege_type=? WHERE user_id=(SELECT id FROM users WHERE name LIKE ?) AND chan_id=(SELECT id FROM chans WHERE name LIKE ?);');
		$sth->execute($privileges,$username,$chan_nom);
	}
}

sub quit_user {
	my ( $classe, $user ) = @_;
	my $sth=$dbh->prepare('DELETE FROM presences WHERE user_id = (SELECT id FROM users WHERE name LIKE ?);');
	$sth->execute($user);
}

sub part_user {
	my ( $class, $chan, $user ) = @_;
	my $sth=$dbh->prepare('DELETE FROM presences WHERE user_id = (SELECT id FROM users WHERE name LIKE ?) AND chan_id=(SELECT id FROM chans WHERE name LIKE ?);');
	$sth->execute($user,$chan);
}

sub nick_user {
	my ( $classe, $old_user, $new_user ) = @_;
	my $sth=$dbh->prepare('UPDATE users SET name=? WHERE name=?');
	$sth->execute($new_user,$old_user);
}

sub chan_mode {
	my ($classe, $chan, $str, $args) = @_;
	my $sth;
	if($str=~/^\+([vbo])$/)
	{
		$sth=$dbh->prepare('UPDATE presences SET privilege_type=? WHERE user_id=(SELECT id FROM users WHERE name LIKE ?) AND chan_id=(SELECT id FROM chans WHERE name LIKE ?);');
		if($1=='v')
		{
			$sth->execute(4,$args,$chan);
		}
		elsif($1=='o')
		{
			$sth->execute(8,$args,$chan);

		}elsif($1=='b')
		{
			$sth->execute(0,$args,$chan);
		}
	}elsif($str=~/^-([vbo])$/)
	{
		$sth=$dbh->prepare('UPDATE presences SET privilege_type=? WHERE user_id=(SELECT id FROM users WHERE name LIKE ?) AND chan_id=(SELECT id FROM chans WHERE name LIKE ?);');
		if($1=='v')
		{
			$sth->execute(4,$args,$chan);
		}
		elsif($1=='o')
		{
			$sth->execute(8,$args,$chan);

		}elsif($1=='b')
		{
			$sth->execute(0,$args,$chan);
		}

	}
}

sub user_mode {
	my ($classe, $chan, $str, $args) = @_;
}

sub DESTROY {
	print "il a cass� mon chan !\n";
}

1;