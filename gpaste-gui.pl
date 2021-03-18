#! /usr/bin/env perl
# Author: Viacheslav Lotsmanov <lotsmanov89@gmail.com>
# License: GNU/GPLv3 https://raw.githubusercontent.com/unclechu/gpaste-gui/master/LICENSE
# Rewritten previous implementation https://github.com/unclechu/gpaste-zenity
use v5.24; use strict; use warnings;
use utf8; use open ':std', ':encoding(UTF-8)';
use experimental qw/smartmatch/;
use Getopt::Long;
use Pod::Usage;
use List::Util qw/first/;
use Glib qw/TRUE FALSE/;
use Gtk2 qw/-init/;
use Gtk2::SimpleList;
use Gtk2::Gdk::Keysyms;

my $show_help = 0;
my $select_by_numbers = 0;
my $mode = 'select';

my @available_modes = qw(
  select
  delete
  select-password
  mask-password
  mask-last-password
  rename-password
  select-and-rename-password
  heal
  tmux
  choose
);

my $line_more = '…';
my $contents_limit = 80;
my $real_contents_limit = $contents_limit - length $line_more;
my $wnd_title = 'GPaste GUI';

my $gpaste_bin = sub {
  return 'gpaste-client' if `which gpaste-client 2>&-`;
  return 'gpaste' if `which gpaste 2>&-`;
  undef
}->();

sub fail_usage { pod2usage(-exitval => 1, -verbose => 1) }

GetOptions(
  'help|?' => \$show_help,
  'numbers' => \$select_by_numbers,

  "mode=s" => sub {
    unless ($_[1] ~~ @available_modes) {
      say STDERR "Unknown mode: '$_[1]'";
      fail_usage;
    }

    $mode = $_[1];
  },

) || fail_usage;

pod2usage(-exitval => 2, -verbose => 2) if $show_help;
my $is_gtk_main_run = 0;
my $exit_code;

sub end_gtk_main {
  $exit_code = (scalar(@_) > 0) ? shift : 0 unless $exit_code;
  if ($is_gtk_main_run) {Gtk2->main_quit; $is_gtk_main_run = 0}
}

sub new_wnd {
  my $wnd = Gtk2::Window->new('toplevel');
  $wnd->set_title($wnd_title);
  $wnd->set_border_width(10);
  $wnd->set_type_hint('dialog');
  $wnd->set_position('center-always');
  $wnd->signal_connect(delete_event => sub { FALSE });

  $wnd->signal_connect(key_press_event => sub {
    my $k = $_[1]->keyval();
    my $x = first { $Gtk2::Gdk::Keysyms{$_} == $k } keys %Gtk2::Gdk::Keysyms;
    end_gtk_main if $x eq 'Escape';
    FALSE
  });

  $wnd
}

sub new_okay_cancel {
  my ($wnd, $ok_cb) = @_;
  my $cancel = Gtk2::Button->new('Cancel');
  my $ok = Gtk2::Button->new('OK');
  $cancel->signal_connect(clicked => sub { $wnd->destroy });
  $ok->signal_connect(clicked => $ok_cb);
  my $box = Gtk2::HButtonBox->new;
  $box->add($cancel);
  $box->add($ok);
  $box
}

sub show_modal {
  my ($parent, $type, $text) = @_;

  my $dialog = Gtk2::MessageDialog->new_with_markup(
    $parent, [qw/modal destroy-with-parent/], $type, 'ok', $text
  );

  $dialog->set_title($wnd_title);
  $dialog->set_position('center-always');
  $dialog->signal_connect(response => sub { shift->destroy });
  $dialog->run;
  $dialog
}

sub warn_modal { show_modal shift, 'warning', shift }
sub err_modal  { show_modal shift, 'error',   shift }

sub dying_modal {
  my $err_msg = shift;
  my $dialog = err_modal undef, $err_msg;

  $dialog->signal_connect(destroy => sub {
    say STDERR $err_msg;
    exit 1;
  });
}

sub input_dialog {
  my ($parent, $label_text, $initial_input) = @_;
  $initial_input = '' unless defined $initial_input;

  my $dialog = Gtk2::Dialog->new(
    $wnd_title, $parent, [qw/modal destroy-with-parent/],
    'gtk-cancel' => 'cancel',
    'gtk-ok' => 'ok',
  );

  my $label = Gtk2::Label->new($label_text);

  my $entry = Gtk2::Entry->new;
  $entry->set_text($initial_input);

  $entry->signal_connect(activate => sub {
    $dialog->response('ok') if $entry->get_text ne ''
  });

  my $box = Gtk2::VBox->new;
  $box->add($label);
  $box->add($entry);
  $dialog->get_content_area()->add($box);
  $dialog->set_default_response('cancel');
  $dialog->set_position('center-always');
  $dialog->show_all;
  my $response = $dialog->run;
  my $text = $entry->get_text;
  $dialog->destroy;
  $_ = ($response eq 'ok') ? $text : undef
}

sub fuzzy_ins_search {
  my ($model, $col, $query, $iter) = @_;
  $query = lc $query;
  my $iter_str = lc $model->get($iter, $col);
  if (index($iter_str, $query) != -1) {FALSE} else {TRUE}
}

sub clear_str { $_ = $_[0] || $_; s/[\t\r\n ]+/ /g; s/(^\s+|\s+$)//g; $_ }
my $item_reg = qr/^([0-9]+): (.*)$/;
my $password_reg = qr/^\[Password\] (.+)$/;

sub parse_line {
  $_ = $_[0] || $_;
  /$item_reg/;
  my $num = $1 + 0;
  $_ = $2; clear_str;

  if ($2 =~ /$password_reg/) {
    $_ = $1;
    clear_str;
    $_ = "Password 🔑 $_";
  } elsif (length($_) > $contents_limit) {
    $_ = substr($_, 0, $real_contents_limit) . $line_more;
  }

  my %result = (num => $num, contents => $_);
}

sub parse_password {
  $_ = $_[0] || $_;
  /$item_reg/;
  my $num = $1 + 0;
  $_ = $2; /$password_reg/; $_ = $1; clear_str;
  my %result = (num => $num, contents => $_);
}

sub safe_run {
  return @_ if $? == 0;
  dying_modal "Child process is failed with $? status"
}

sub get_history {
  chomp(my @history = safe_run `$gpaste_bin history --oneline`);
  my @passwords = grep { /^[0-9]+: \[Password\] / } @history;
  @history = map { my %x = parse_line; \%x } @history;
  @passwords = map { my %x = parse_password; \%x } @passwords;
  my %result = (all => \@history, passwords => \@passwords);
}

sub guard_non_empty_history {
  my %history = %{(shift)};
  my $key = shift || 'all';

  dying_modal 'Clipboard history is empty'
    if scalar(@{$history{all}}) == 0;

  dying_modal q/There's no passwords in clipboard history/
    if $key eq 'passwords' && scalar(@{$history{passwords}}) == 0;
}

sub mask_password_with_name {
  my ($num, $name, @passwords) = (shift, shift, @{(shift)});
  my $already_masked = first { $_->{num} == $num } @passwords;

  dying_modal 'Name for masking password is unexpectedly undefined'
    unless defined $name;

  dying_modal 'Name for masking password is empty' if $name eq '';

  if (defined $already_masked) {
    safe_run system
      $gpaste_bin, 'rename-password', $already_masked->{contents}, $name
  } else {
    safe_run system $gpaste_bin, 'set-password', $num, $name
  }
}

sub generic_select_from_history {
  my ($sub_title, $item_text_prefix, $is_multiple) = (shift, shift, shift);
  my @history = @{(shift)};
  my $cb = shift;

  my $wnd = new_wnd;
  my $is_acted = 0;
  $wnd->signal_connect(destroy => sub { end_gtk_main unless $is_acted });

  my $list = Gtk2::SimpleList->new(
    $select_by_numbers ?
      ('#' => 'text', 'Contents' => 'text') :
      ('Contents' => 'text', '#' => 'text')
  );

  $list->set_search_equal_func(\&fuzzy_ins_search);
  $list->get_selection->set_mode('multiple') if $is_multiple;

  unless ($select_by_numbers) {
    $list->set_headers_visible(0);
    $list->get_column(1)->set_visible(0);
  }

  @{$list->{data}} = do {
    my $f =
      $select_by_numbers ?
        sub { [$_->{num}, $item_text_prefix . $_->{contents}] } :
        sub { [$item_text_prefix . $_->{contents}, $_->{num}] };

    map { $f->() } @history;
  };

  my $handler = sub {
    my @selected = $list->get_selected_indices;

    if (scalar(@selected) == 0) {
      warn_modal $wnd, 'Select an item first';
      return
    }

    @selected = map { $history[$_] } @selected;
    my $result = $cb->($is_multiple ? \@selected : $selected[0], $wnd);

    unless (defined $result && $result eq 'continue') {
      $is_acted = 1;
      $wnd->destroy; # `$list` will be dead here
    }
  };

  $list->signal_connect(row_activated => $handler);

  my $box = Gtk2::VBox->new;
  $box->add(Gtk2::Label->new("GPaste ($sub_title)"));
  my $scroll = Gtk2::ScrolledWindow->new; # TODO hide horizontal scrollbar
  $scroll->set_size_request(800, 600); # TODO expand size and resize main window
  $scroll->add($list);
  $box->add($scroll);
  $box->add(new_okay_cancel $wnd, $handler);
  $wnd->add($box);
  $wnd->show_all;
}

sub get_name_for_password {
  my $parent = shift;
  my $title = shift;
  my @passwords = @{(shift)};
  my $x = shift; # initial value
  my $soft_cancel = shift || 0;
  my $is_canceled = 0;

  my $get_new_name = sub {
    input_dialog $parent, 'Enter new name for the password', $x;

    unless (defined) {
      if ($soft_cancel) {$is_canceled = 1; return} else {exit 0}
    }

    clear_str;

    if ($_ eq '') {
      warn_modal $parent, 'Password name cannot be empty';
      return
    }

    $_
  };

  while (1) {
    $x = $get_new_name->();
    return if $is_canceled;
    next unless defined $x;
    my $found = first { $_->{contents} eq $x } @passwords;

    unless (defined $found) { return $x } else {
      warn_modal $parent, "Password name '$x' is already taken";
      next
    }
  }
}

my %actions;

sub choose_action {
  my $wnd = new_wnd;
  my $is_acted = 0;
  $wnd->signal_connect(destroy => sub { end_gtk_main unless $is_acted });

  my $list = Gtk2::SimpleList->new(
    'Action' => 'text',
    'System action' => 'text',
  );

  $list->set_headers_visible(0);
  $list->get_column(1)->set_visible(0);
  $list->set_search_equal_func(\&fuzzy_ins_search);

  @{$list->{data}} = (
    ['Select',                             'select'],
    ['Delete',                             'delete'],
    ['Select password',                    'select-password'],
    ['Mask last password with name',       'mask-last-password'],
    ['Select password and mask with name', 'mask-password'],
    ['Rename password',                    'rename-password'],
    ['Select password and rename',         'select-and-rename-password'],
    ['Heal clipboard',                     'heal'],
    ['Copy from tmux',                     'tmux'],
  );

  unless ($select_by_numbers) {
    push @{$list->{data}}, ['* select by numbers *', 'select-by-numbers']
  }

  my $handler = sub {
    my $selected = $list->get_selection()->get_selected();

    unless (defined $selected) {
      warn_modal $wnd, 'Select an item first';
      return;
    }

    $is_acted = 1;
    my $action = $list->get_model()->get_value($selected, 1);
    $wnd->destroy; # `$list` will be dead here

    if ($action eq 'select-by-numbers') {
      $select_by_numbers = 1;
      $actions{choose}->();
    } elsif (exists $actions{$action}) {
      $actions{$action}->();
    } else {
      dying_modal "Action '$action' is unexpectedly not implemented";
    }
  };

  $list->signal_connect(row_activated => $handler);

  my $label_text = do {
    $_ = 'GPaste (choose action)';
    if ($select_by_numbers) {"$_ +numbers"} else {$_}
  };

  my $box = Gtk2::VBox->new;
  $box->add(Gtk2::Label->new($label_text));
  $box->add($list);
  $box->add(new_okay_cancel $wnd, $handler);
  $wnd->add($box);
  $wnd->show_all;
}

sub select_from_history {
  my %history = get_history;
  guard_non_empty_history \%history;

  generic_select_from_history 'select', '', 0, $history{all}, sub {
    my %selected = %{(shift)};
    safe_run `$gpaste_bin select $selected{num}`;
    end_gtk_main
  }
}

sub delete_from_history {
  my %history = get_history;
  guard_non_empty_history \%history;
  my $gen_pass_name = sub { '__marked_to_delete_' . shift };

  generic_select_from_history 'delete', '', 1, $history{all}, sub {
    my @selected = @{(shift)};

    mask_password_with_name
      $_->{num},
      $gen_pass_name->($_->{num}),
      $history{passwords}
        for @selected;

    safe_run system
      $gpaste_bin, 'delete-password', $gen_pass_name->($_->{num})
        for @selected;

    end_gtk_main
  }
}

sub select_a_password_from_history {
  my %history = get_history;
  guard_non_empty_history \%history, 'passwords';

  generic_select_from_history
    'select password', '🔑 ', 0, $history{passwords}, sub {
      my %selected = %{(shift)};
      safe_run `$gpaste_bin select $selected{num}`;
      end_gtk_main
    }
}

sub mask_a_password {
  my %history = get_history;
  guard_non_empty_history \%history;

  generic_select_from_history
    'select password to mask', '', 0, $history{all}, sub {
      my %selected = %{(shift)};
      my @passwords = @{$history{passwords}};
      my $wnd = shift;
      my $found_pass = first { $_->{num} == $selected{num} } @passwords;

      my $title =
        defined($found_pass) ?
          'Enter new name for the password' :
          'Enter a name for the password';

      my $pass_name =
        get_name_for_password
          $wnd,
          $title,
          \@passwords,
          (defined $found_pass) ? $found_pass->{contents} : undef,
          1;

      return 'continue' unless defined $pass_name;
      mask_password_with_name $selected{num}, $pass_name, $history{passwords};
      end_gtk_main
    }
}

sub mask_last_password {
  my %history = get_history;
  guard_non_empty_history \%history;
  my %last = %{$history{all}->[0]};

  my $is_pass =
    scalar(@{$history{passwords}}) > 0 &&
    $history{passwords}->[0]->{num} == $last{num};

  %last = %{$history{passwords}->[0]} if $is_pass;

  my $pass_name =
    get_name_for_password
      undef,
      $is_pass ?
        'Enter new name for the password' :
        'Enter a name for the password',
      $history{passwords},
      $is_pass ? $last{contents} : undef;

  mask_password_with_name $last{num}, $pass_name, $history{passwords};
  end_gtk_main
}

sub rename_a_password {
  my %history = get_history;
  my @passwords = @{$history{passwords}};
  guard_non_empty_history \%history, 'passwords';

  my $get_old_name = sub {
    input_dialog undef, 'Enter previous name of the password', shift;
    exit 0 unless defined;
    clear_str;

    if ($_ eq '') {
      warn_modal undef, 'Password name cannot be empty';
      return
    }

    $_
  };

  my %old_item = do {
    my $x;

    while (1) {
      $x = $get_old_name->($x);
      next unless defined $x;
      my $found = first { $_->{contents} eq $x } @passwords;

      if (defined $found) { $x = $found; last } else {
        warn_modal undef, "Password with name '$x' not found";
        next
      }
    }

    %{$x}
  };

  my $new_name =
    get_name_for_password
      undef,
      'Enter new name for the password',
      \@passwords,
      $old_item{contents};

  mask_password_with_name $old_item{num}, $new_name, $history{passwords};
  end_gtk_main
}

sub select_and_rename_a_password {
  my %history = get_history;
  guard_non_empty_history \%history, 'passwords';

  generic_select_from_history
    'select password to rename', '🔑 ', 0, $history{passwords}, sub {
      my %selected = %{(shift)};
      my $wnd = shift;

      my $new_name =
        get_name_for_password
          $wnd,
          'Enter new name for the password',
          $history{passwords},
          $selected{contents},
          1;

      return 'continue' unless defined $new_name;
      mask_password_with_name $selected{num}, $new_name, $history{passwords};
      end_gtk_main
    }
}

sub heal_clipboard {
  my %history = get_history;
  guard_non_empty_history \%history;

  if (scalar(@{$history{all}}) >= 2) {
    safe_run `$gpaste_bin select 1`;
    safe_run `$gpaste_bin select 1`;
  } else {
    safe_run system
      $gpaste_bin, 'add', '--',
      "--gpaste-gui.pl heal clipboard plug @{[time(), rand()]}--";

    safe_run `$gpaste_bin select 1`;
    safe_run `$gpaste_bin delete 1`;
  }

  end_gtk_main
}

sub add_from_tmux {
  my $buffer = `tmux showb`;

  dying_modal "Reading last tmux buffer is failed with status code: $?"
    if ($? != 0) || !defined($buffer);

  open(my $h, "|$gpaste_bin");
  print $h $buffer;
  close($h);

  end_gtk_main
}

%actions = (
  'choose' => \&choose_action,
  'select' => \&select_from_history,
  'delete' => \&delete_from_history,
  'select-password' => \&select_a_password_from_history,
  'mask-password' => \&mask_a_password,
  'mask-last-password' => \&mask_last_password,
  'rename-password' => \&rename_a_password,
  'select-and-rename-password' => \&select_and_rename_a_password,
  'heal' => \&heal_clipboard,
  'tmux' => \&add_from_tmux,
);

if (defined $gpaste_bin) {
  $actions{$mode}->();
} else {
  dying_modal 'GPaste client tool not found';
}

$is_gtk_main_run = 1;
if (defined $exit_code) {exit $exit_code} else {Gtk2->main}

__END__

=encoding UTF-8

=head1 DESCRIPTION

GUI for GPaste.

=head1 SYNOPSIS

gpaste-gui.pl [options]

  Options:
    --help -h -?
      Show this usage info

    --numbers -n
      Selection by numbers

    --mode=[mode] -m=[mode]
      Possible `mode`s:
        "select" (default) to select an item from history
        "delete" to select an item to delete it from history
        "select-password"
          to select a password from history (only passwords are shown)
        "mask-password"
          to select an item from history
          to mask it with specified name as a password
          or to rename a password if an item is masked already
        "mask-last-password"
          to mask last item in list with specified name as a password
        "rename-password"
          to rename a password (by specifying old name and new one)
        "select-and-rename-password"
          to select a password from history (only passwords are shown)
          and give it a new name
        "heal"
          to swap **twice** last two items from history
          (so the history would look like nothing happened).
          Sometimes I can't paste to terminal and to Vim from "+ register,
          `xsel -o` returns nothing, like the buffer is empty
          (I don't know yet why and in which case it happens),
          this simple hack fixes this issue.
        "tmux" to copy last buffer from default tmux session
        "choose" to show GUI menu to choose one of these modes
=cut
