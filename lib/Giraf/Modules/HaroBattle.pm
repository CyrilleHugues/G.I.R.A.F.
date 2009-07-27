package Giraf::Modules::HaroBattle;

use strict;

use Giraf::Module;

use List::Util qw[min max];
use POSIX qw(ceil floor);
use Switch;
use POE;

# Private vars
our $_kernel;
my $_chan = "#harobattle";
my $_help_url = "http://giraf.gentilboulet.info/fr/modules/harobattle.php";

# Match and bet controls
my $_match_en_cours;
my $_continuer;
my $_paris_ouverts;
my $_bets;
my $_pot;
my $_reward;

# The haros
my $_nb_haros = 8;
my $_champion;
my $_challenger;

# Statistics about the haros
my $_consecutive_victories = 0;

# Database stuff
my $_tbl_haro = "mod_harobattle_haros"; # Haros table, contains everything there is to know about the haros
my $_tbl_betters = "mod_harobattle_betters"; # Betters table, contains wealth and uuid of the betters
my $_tbl_data = "mod_harobattle_data"; # Data table, contains the current champion id and his consecutive victories
my $_dbh = Giraf::Admin::get_dbh(); # GIFAR database

sub init {
	my ($ker,$irc_session) = @_;
	$_kernel=$ker;
	Giraf::Core::debug("HAROBATTLE INIT");
	Giraf::Chan::join($_chan);
	get_betters();
	Giraf::Trigger::register('public_function','harobattle','harobattle_main',\&harobattle_main,'harobattle|hb');
#	Giraf::Trigger::register('public_function','harobattle','hb_main',\&harobattle_main,'hb');
}
 
sub unload {
	Giraf::Trigger::unregister('public_function','harobattle','harobattle_main');
}

sub harobattle_main {
	my ($nick, $dest, $what) = @_;
	my @return;
	my ($sub_func, $args);
	$what =~ m/^((.+?))?(\s+(.+))?$/;

	$sub_func = $2;
	$args = $4;

	Giraf::Core::debug("harobattle_main : sub_func = \"$sub_func\"");

	switch ($sub_func) {
		case 'original' { push(@return, harobattle_original($nick, $dest, $args)); }
		case 'bet'      { push(@return, harobattle_bet($nick, $dest, $args)); }
		case 'root'     { push(@return, harobattle_root($nick, $dest, $args)); }
		case 'stop'     { push(@return, harobattle_stop($nick, $dest, $args)); }
		else            { push(@return, harobattle_help($nick, $dest, $sub_func)); }
	}

	return @return;
}

sub harobattle_original {
	my ($nick, $dest, $args) = @_;
	my @return;

	Giraf::Core::debug("harobattle_original : args = \"$args\"");

	if ($_match_en_cours) {
		if (!$_continuer) {
			$_continuer = 1;
			push(@return, linemaker("OK, on arrête pas alors, faudrait savoir..."));
			return @return;
		}
		push(@return, linemaker("Un match est déjà en cours, un peu de patience."));
		return @return;
	}

	my $champion = get("champion_id");
	$_pot = get("pot");
	$_reward = get("reward");
	$_consecutive_victories = get("consecutive_victories");

	$_champion = chargement($champion);

	$_match_en_cours = 1;
	$_continuer = 5;

	$_kernel->post('harobattle_core', 'harobattle_original', $dest, 1);

	return @return;
}

sub harobattle_bet {
	my ($nick, $dest, $args) = @_;
	my @return;

	Giraf::Core::debug("harobattle_bet : args = \"$args\"");

	my $uuid = Giraf::User::getUUID($nick);

	$args =~ m/^(.+?)(\s+([0-9]+))(.*?)$/;

	my $result = $1;
	my $bet = $3;

	if (!$_bets->{$uuid}) {
		my $name = Giraf::User::getNickFromUUID($uuid);
		push(@return, linemaker("Un compte pour $name vient d'être créé. La banque vous offre 20."));
		$_bets->{$uuid}->{wealth} = 20;
		$_bets->{$uuid}->{result} = -1;
		$_bets->{$uuid}->{colour} = "";
	}

	if ($args eq "") {
		push (@return, linemaker("Vous avez une fortune de ".$_bets->{$uuid}->{wealth}."."));
	}
	elsif (!$_paris_ouverts) {
		push (@return, linemaker("Les paris sont fermés pour le moment, attendez l'annonce d'un match."));
	}
	elsif ($_bets->{$uuid}->{result} != -1) {
		push (@return, linemaker("Vous avez déjà parié pour ce match."));
	}
	elsif ($bet > $_bets->{$uuid}->{wealth}) {
		push (@return, linemaker("Vous n'avez pas assez d'argent pour parier cette somme."));
	}
	elsif ($bet == 0) {
		push (@return, linemaker("Vous ne pouvez pas parier 0."));
	}
	else {
		if ($result eq $_champion->{nom}) {
			$_bets->{$uuid}->{result} = $_champion->{id};
		}
		elsif ($result eq $_challenger->{nom}) {
			$_bets->{$uuid}->{result} = $_challenger->{id};
		}
		elsif ($result eq "draw") {
			$_bets->{$uuid}->{result} = 0;
		}
		else {
			push (@return, linemaker("Mais n'importe quoi, vous n'avez pas le droit de parier pour $result"));
			return @return;
		}

		$_bets->{$uuid}->{bet} = $bet;
		$_bets->{$uuid}->{wealth} -= $bet;
		$_pot += $bet;

		push (@return, linemaker("Votre pari de $bet a été enregistré."));
	}
	return @return;
}

sub harobattle_help {
	my ($nick, $dest, $sub_func) = @_;
	my @return;

	Giraf::Core::debug("harobattle_help : args = \"$sub_func\"");

	push(@return, linemaker($_help_url));
	return @return;
}

sub harobattle_root {
	my ($nick, $dest, $args) = @_;
	my $haro;
	my $not_found = 1;
	my $uuid = Giraf::User::getUUID($nick);
	my @return;

	Giraf::Core::debug("harobattle_root : args = \"$args\"");

	if (!$_bets->{$uuid}) {
		push(@return, linemaker("Vous n'avez pas encore de compte."));
		return @return;
	}

	if ($_bets->{$uuid}->{wealth} < 50) {
		push(@return, linemaker("Soutenir un haro coûte 50, vous n'avez pas assez d'argent."));
		return @return;
	}

	for (my $i = 1; ($i <= $_nb_haros) && $not_found; $i++) {
		$haro = chargement($i);
		if ($args eq $haro->{nom}) {
			$_bets->{$uuid}->{colour} = $haro->{couleur};
			$_bets->{$uuid}->{wealth} -= 50;
			$not_found = 0;
		}
	}

	if ($not_found) {
		push(@return, linemaker("$args n'est pas un haro existant."));
	}
	else {
		push(@return, linemaker("Vous soutenez maintenant ".nom($haro)."."));
	}

	return @return;
}

sub harobattle_stop {
	my ($nick, $dest, $args) = @_;
	my @return;

	Giraf::Core::debug("harobattle_stop : args = \"$args\"");

	if($_continuer) {
		push(@return, linemaker("OK, on arrête après le prochain duel."));
	}

	$_continuer = 0;

	return @return;
}

sub get_betters {
	my $sth = $_dbh->prepare("SELECT * FROM $_tbl_betters");
	my ($uuid, $wealth, $colour);
	$sth->bind_columns(\$uuid, \$wealth, \$colour);
	$sth->execute();

	while ($sth->fetch()) {
		$_bets->{$uuid} = {
			"wealth" => $wealth,
			"colour" => $colour,
			"result" => -1
		}
	}
}
 

sub set_betters {
	my $sth = $_dbh->prepare("INSERT OR REPLACE INTO $_tbl_betters (uuid, wealth, colour) VALUES (?, ?, ?)");

	foreach my $i (keys %$_bets) {
		$sth->execute($i, $_bets->{$i}->{wealth}, $_bets->{$i}->{colour});
	}
}

sub get {
	my ($key) = @_;
	my $value;

	my $sth = $_dbh->prepare("SELECT value FROM $_tbl_data WHERE key=?");
	$sth->bind_columns(\$value);
	$sth->execute($key);
	$sth->fetch();

	return $value;
}

sub set {
	my ($key, $value) = @_;

	my $sth = $_dbh->prepare("UPDATE $_tbl_data SET value=? WHERE key=?"); 
	$sth->execute($value, $key);
}

sub linemaker {
	my ($texte) = @_;

	return { action =>"MSG", dest=>$_chan, msg=>$texte };
}


sub nom {
	my ($haro) = @_;

	# Renvoie le nom du haro avec les tags de couleur

	return "[c=".$haro->{couleur}."]haro[".$haro->{nom}."][/c]";
}

sub sante {
	# Renvoie la barre de santé des haros

	my $scale = ceil((18 * $_champion->{points_vie}) / $_champion->{points_vie_total});

	my $result = "[[c=vert]";
	for (my $i = 18; $i > 0; $i--) {

		# Met les couleurs
		if ($i == 12) {
			$result .= "[/c][c=jaune]";
		}
		else {
			if ($i == 6) {
				$result .= "[/c][c=rouge]";
			}
		}

		# Affiche la barre
		if ($i > $scale) {
			$result .= " ";
		}
		else {
			$result .= "|";
		}
	}
	$result .= "[/c]] ".nom($_champion)." / ".nom($_challenger)." [[c=rouge]";

	$scale = ceil((18 * $_challenger->{points_vie}) / $_challenger->{points_vie_total});
	
	for (my $i = 1; $i < 19; $i++) {

		# Met les couleurs
		if ($i == 7) {
			$result .= "[/c][c=jaune]";
		}
		else {
			if ($i == 13) {
				$result .= "[/c][c=vert]";
			}
		}

		# Affiche la barre
		if ($i > $scale) {
			$result .= " ";
		}
		else {
			$result .= "|";
		}
	}
	$result .= "[/c]]";
}

sub chargement {
	my ($ref) = @_;
	# Load a haro from the database

	my $sth = $_dbh->prepare("SELECT * FROM $_tbl_haro WHERE id=?");
	my $haro;
	$sth->bind_columns(\$haro->{id}, \$haro->{nom}, \$haro->{couleur}, \$haro->{precision}, \$haro->{esquive}, \$haro->{charisme}, \$haro->{armure}, \$haro->{points_vie}, \$haro->{arme}, \$haro->{puissance}, \$haro->{coups}, \$haro->{recharge}, \$haro->{munitions});
	$sth->execute($ref);

	if ($sth->fetch()) {
		$haro->{points_vie_total} = $haro->{points_vie};
		$haro->{charisme_fail} = 0;
		$haro->{precision_fail} = 0;
		return $haro;
	}
	else {
	}

}

sub initiative {
	# renvoie nombre de coups d'avance du haro champion

	my $jet1 = taunt($_champion);
	my $jet2 = taunt($_challenger);

	return $jet1 - $jet2;
}

sub taunt {
	my ($haro) = @_;
	my @return;
	my ($texte, $taunt);

	# prends en parametre un haro
	# envoie un message de taunt approprie sur la sortie, et renvoie le resultat du jet

	my $de = int(rand(12))+1;

	if ($de == 12) {
		# Envoie un message de taunt qui faile violemment

		push(@return, linemaker(nom($haro)." : MAMAN ! J'ai PEUR !!!"));
		Giraf::Core::emit(@return);

		$haro->{charisme_fail}++;
		return -1;
	}
	elsif ($de > $haro->{charisme}) {
		# Envoie un mauvais message de taunt (ou rien)

		push(@return, linemaker(nom($haro)." : ..."));
		Giraf::Core::emit(@return);

		return 0;
	}
	else {
		# Envoie un message de taunt qui win

		push(@return, linemaker(nom($haro)." : Tiens toi tranquille, ça va pas durer longtemps !"));
		Giraf::Core::emit(@return);

		return 1;
	}
}

sub debuffs {
	$_champion->{charisme} -= $_champion->{charisme_fail};
	$_champion->{precision} -= $_champion->{precision_fail};
	$_challenger->{charisme} -= $_challenger->{charisme_fail};
	$_challenger->{precision} -= $_challenger->{precision_fail};

	$_champion->{charisme_fail} = 0;
	$_champion->{precision_fail} = 0;
	$_challenger->{charisme_fail} = 0;
	$_challenger->{precision_fail} = 0;

	if ($_champion->{charisme} < 1) { $_champion->{charisme} = 1; }
	if ($_champion->{precision} < 1) { $_champion->{precision} = 1; }
	if ($_challenger->{charisme} < 1) { $_challenger->{charisme} = 1; }
	if ($_challenger->{precision} < 1) { $_challenger->{precision} = 1; }
}

sub round {
	my ($initiative, $i) = @_;

	my @return;

	# Déroulement d'un round
	push(@return, linemaker("Round ".$i));
	push(@return, linemaker(sante()));

	Giraf::Core::emit(@return);
	undef @return;

	debuffs();
	my ($k, $l);

	if ($initiative > 0) {
		$k = $i;
		$l = $i - $initiative;
	}
	else {
		$k = $i + $initiative;
		$l = $i;
	}

	if ($i > -$initiative) {
		push(@return, attaque($_champion, $_challenger, $k));
	}
	else {
		push(@return, linemaker(nom($_champion)." n'as pas encore compris que le match avait commencé."));
	}

	if ($i > $initiative) {
		push(@return, attaque($_challenger, $_champion, $l));
	}
	else {
		push(@return, linemaker(nom($_challenger)." n'as pas encore compris que le match avait commencé."));
	}

	Giraf::Core::emit(@return);

	return ($_champion->{points_vie} > 0) && ($_challenger->{points_vie} > 0) && ($_champion->{munitions} || $_challenger->{munitions});
}

sub attaque {
	my ($haro1, $haro2, $i) = @_;

	my @return;

	# Une attaque

	if ((($i - 1) % ($haro1->{recharge} + 1)) || (!$haro1->{munitions})) {
		if(taunt($haro1) == 1) {
			$haro2->{precision_fail}++;
			push(@return, linemaker(nom($haro2)." semble destabilisé"));
		}
	}
	else {
		for (my $j = 0; $j < $haro1->{coups}; $j++) {
			my $de1 = int(rand(12))+1;
			my $de2 = int(rand(12))+1;
			my $armure = $haro2->{armure} - int(rand($haro2->{armure}/2));

			if ($armure > $haro1->{puissance}) {
				$armure = $haro1->{puissance};
			}

			if ($de1 == 12) {
				$haro1->{charisme_fail}++;
				if ($de2 == 12) {
					push(@return, linemaker(nom($haro1)." et ".nom($haro2)." trébuchent tous les deux comme des n[c=rouge]00[/c]bs !"));
				}
				else {
					push(@return, linemaker(nom($haro1)." trébuche comme un n[c=rouge]00[/c]b !"));
				}
			}
			elsif ($de1 > $haro1->{precision}) {
				push(@return, linemaker(nom($haro1)." tire avec son ".$haro1->{arme}." et rate."));
				if ($de2 == 12) {
					$haro2->{charisme_fail}++;
					push(@return, linemaker(nom($haro2)." se casse la figure et se prends quand même le coup, le n[c=rouge]00[/c]b ! ".($haro1->{puissance} - $armure)." dégats infligés."));
					$haro2->{points_vie} -= ($haro1->{puissance} - $armure);
				}
			}
			else {
				my $chaine = nom($haro1)." tire avec son ".$haro1->{arme};
				if ($de2 == 12) {
					$haro2->{charisme_fail}++;
					push(@return, linemaker($chaine.", ".nom($haro2)." glisse et perds son armure (comme un n[c=rouge]00[/c]b) : ".$haro1->{puissance}." dégats infligés."));
					$haro2->{points_vie} -= $haro1->{puissance};
				}
				elsif ($de2 > $haro2->{esquive}) {
					push(@return, linemaker($chaine." et inflige ".($haro1->{puissance} - $armure)." dégats à ".nom($haro2)."."));
					$haro2->{points_vie} -= ($haro1->{puissance} - $armure);
				}
				else {
					push(@return, linemaker($chaine." mais ".nom($haro2)." esquive."));
				}
			}
		}
		$haro1->{munitions} -= $haro1->{coups};
	}
	return @return;
}

sub bet_results {
	my ($winner_id) = @_;
	my ($win_bets, $winner, $win, $pot_minus, $counter);
	my @return;

	if ($winner_id) {
		$winner = chargement($winner_id);
		$win = nom($winner);
	}
	else {
		$win = "le match nul";
	}

	foreach my $i (keys %$_bets) {
		if ($_bets->{$i}->{result} == $winner_id) {
			$win_bets += $_bets->{$i}->{bet};
		}
	}

	if ($win_bets) {
		push(@return, linemaker("Résultats des paris : il fallait parier pour $win, mise totale gagnante : $win_bets."));

		if ($winner_id == $_challenger->{id}) {
			push(@return, linemaker("La banque offre $_reward aux parieurs téméraires ayant soutenu ".nom($_challenger)."."));
			$_pot += $_reward;
		}
	}
	else {
		push(@return, linemaker("Résultats des paris : il fallait parier pour $win, bande de n[c=rouge]00[/c]baX."));
	}

	if ($winner_id == $_challenger->{id}) {
		$_reward = 1;
	}

	foreach my $i (keys %$_bets) {
		my $user = Giraf::User::getNickFromUUID($i);
		if ($_bets->{$i}->{result} == $winner_id) {

			my $quantity = int($_pot * $_bets->{$i}->{bet} / $win_bets);

			$pot_minus += $quantity;

			push(@return, linemaker("[c=".$_bets->{$i}->{colour}."]$user\[/c] (+".($quantity - $_bets->{$i}->{bet}).", mise ".$_bets->{$i}->{bet}.")"));

			$_bets->{$i}->{wealth} += $quantity;
			$counter++;
		}
		elsif ($_bets->{$i}->{result} > -1) {
			push(@return, linemaker("[c=".$_bets->{$i}->{colour}."]$user\[/c] (-".$_bets->{$i}->{bet}.")"));
			$counter++;
		}

		if ($_bets->{$i}->{wealth} < 5) {
			$_bets->{$i}->{wealth}++;
		}

		$_bets->{$i}->{result} = -1;
		$_bets->{$i}->{bet} = 0;
	}

	if (!$counter) {
		$_continuer--;
	}
	else {
		$_continuer = 5;
	}

	$_pot -= $pot_minus;

	if ($_pot) {
		push(@return, linemaker("Il reste $_pot dans le pot."));
	}

	return @return;
}
	

######## ##     ## ######## ##    ## ########    ##     ##    ###    ##    ## ########  ##       ######## ########   ######  
##       ##     ## ##       ###   ##    ##       ##     ##   ## ##   ###   ## ##     ## ##       ##       ##     ## ##    ## 
##       ##     ## ##       ####  ##    ##       ##     ##  ##   ##  ####  ## ##     ## ##       ##       ##     ## ##       
######   ##     ## ######   ## ## ##    ##       ######### ##     ## ## ## ## ##     ## ##       ######   ########   ######  
##        ##   ##  ##       ##  ####    ##       ##     ## ######### ##  #### ##     ## ##       ##       ##   ##         ## 
##         ## ##   ##       ##   ###    ##       ##     ## ##     ## ##   ### ##     ## ##       ##       ##    ##  ##    ## 
########    ###    ######## ##    ##    ##       ##     ## ##     ## ##    ## ########  ######## ######## ##     ##  ######  

sub hb_init {
  my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
  $_[KERNEL]->alias_set('harobattle_core');
}
 
sub hb_stop {
}

sub hb_original {
	my ($kernel, $heap, $dest) = @_[ KERNEL, HEAP, ARG0 ];
	my @return;

	Giraf::Core::debug("hb_original");

	my $challenger = int(rand($_nb_haros - 1) + 1);

	if($challenger >= $_champion->{id}) {
		$challenger++;
	}

	$_challenger = chargement($challenger);

	push(@return, linemaker("Le prochain duel va opposer le champion ".nom($_champion)." au challenger ".nom($_challenger)." dans 5 minutes."));
	push(@return, linemaker("Les paris sont ouverts !"));

	$_paris_ouverts = 1;

	$kernel->delay_set('harobattle_annonce', 60, $dest, 4);

	Giraf::Core::emit(@return);
}

sub hb_championnat {
}

sub hb_annonce {
	my ($kernel, $heap, $dest, $delai) = @_[ KERNEL, HEAP, ARG0, ARG1 ];
	my @return;
	my $new_delai = $delai - 1;
	my $line = "Le prochain duel va opposer ".nom($_champion)." et ".nom($_challenger)." dans ".$delai." minute";

	Giraf::Core::debug("hb_annonce");


	if ($new_delai) {
		$kernel->delay_set('harobattle_annonce', 60, $dest, $new_delai);
		$line .= "s.";
	}
	else {
		$kernel->delay_set('harobattle_initiative', 60, $dest, $line .= ".");
	}

	push(@return, linemaker($line));

	Giraf::Core::emit(@return);
}

sub hb_initiative {
	my ($kernel, $heap, $dest) = @_[ KERNEL, HEAP, ARG0 ];
	my @return;

	Giraf::Core::debug("hb_initiative");

	push (@return, linemaker("Les paris sont fermés."));
	Giraf::Core::emit(@return);

	$_paris_ouverts = 0;
	my $initiative = initiative();

	$kernel->delay_set('harobattle_round', 15, $dest, $initiative, 1);
}

sub hb_round {
	my ($kernel, $heap, $dest, $initiative, $i) = @_[ KERNEL, HEAP, ARG0, ARG1, ARG2 ];

	Giraf::Core::debug("hb_round");

	if(round($initiative, $i)) {
		$kernel->delay_set('harobattle_round', 20, $dest, $initiative, $i + 1);
	}
	else {
		$kernel->delay_set('harobattle_atwi', 20, $dest);
	}
}

sub hb_atwi {
	my ($kernel, $heap, $dest) = @_[ KERNEL, HEAP, ARG0 ];
	my @return;
	my $line;

	Giraf::Core::debug("hb_atwi");

	push(@return, linemaker(sante()));

	if (($_champion->{munitions} == 0) && ($_challenger->{munitions} == 0) && ($_champion->{points_vie} > 0) && ($_challenger->{points_vie} >0)) {
		push(@return, linemaker("Plus de munitions ! Le champion ".nom($_champion)." conserve son titre."));

		push(@return, bet_results(0));

		$_champion = chargement($_champion->{id});
	}
	elsif ($_champion->{points_vie} > 0) {
		$_consecutive_victories++;
		$line = "Une ovation pour ".nom($_champion).", qui conserve son titre de champion. ".$_consecutive_victories." victoire";

		if ($_consecutive_victories > 1) {
			$line .= "s consécutives.";
		}
		else {
			$line .= " pour le moment.";
		}
		
		push(@return, linemaker($line));

		push(@return, bet_results($_champion->{id}));

		$_reward += $_consecutive_victories;

		$_champion = chargement($_champion->{id});
	}
	elsif ($_challenger->{points_vie} > 0) {
		$line = "On applaudit tous ".nom($_challenger)." qui vient d'humilier ".nom($_champion);

		if ($_consecutive_victories > 1) {
			$line .= " après ses ".$_consecutive_victories." victoires consécutives.";
		}
		else {
			$line .= ".";
		}

		push(@return, linemaker($line));

		push(@return, bet_results($_challenger->{id}));

		$_consecutive_victories = 1;
		$_champion = chargement($_challenger->{id});
	}
	else {
		push(@return, linemaker("Match nul ! Le champion ".nom($_champion)." conserve son titre."));

		push(@return, bet_results(0));

		$_champion = chargement($_champion->{id});
	}

	set("champion_id", $_champion->{id});
	set("pot", $_pot);
	set("consecutive_victories", $_consecutive_victories);
	set("reward", $_reward);
	set_betters();

	if($_continuer) {
		push(@return, linemaker("Prochain match dans 1 minute."));
		$kernel->delay_set('harobattle_original', 60, $dest);
	}
	else {
		push(@return, linemaker("C'est tout pour le moment, rendez-vous très bientôt."));
		$_match_en_cours = 0;
	}

	Giraf::Core::emit(@return);
}

POE::Session->create(
	inline_states => {
		_start => \&Giraf::Modules::HaroBattle::hb_init,
		_stop => \&Giraf::Modules::HaroBattle::hb_stop,
		harobattle_original => \&Giraf::Modules::HaroBattle::hb_original,
		harobattle_championnat => \&Giraf::Modules::HaroBattle::hb_championnat,
		harobattle_annonce => \&Giraf::Modules::HaroBattle::hb_annonce,
		harobattle_initiative => \&Giraf::Modules::HaroBattle::hb_initiative,
		harobattle_round => \&Giraf::Modules::HaroBattle::hb_round,
		harobattle_atwi => \&Giraf::Modules::HaroBattle::hb_atwi,
	},
);

1;

