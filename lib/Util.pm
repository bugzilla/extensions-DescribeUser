# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the Bugzilla Bug Tracking System.
#
# The Initial Developer of the Original Code is Olav Vitters.
# Portions created by Olav Vitters are
# Copyright (C) 2000 Olav Vitters. All
# Rights Reserved.

package Bugzilla::Extension::DescribeUser::Util;

use strict;
use base qw(Exporter);

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::User;
use Bugzilla::Error;
use Bugzilla::Util;

our @EXPORT = qw(
    page
);

sub page {
    my %params = @_;
    my ($vars, $page) = @params{qw(vars page_id)};
    if ($page =~ /^describeuser\./) {
        _page_describeuser($vars);
    }
}

sub _page_describeuser {
    my $vars = shift;

    my $cgi = Bugzilla->cgi;
    my $dbh = Bugzilla->dbh;
    my $user = Bugzilla->user;

    my $userid = $user->id;

    my $r_userid;
    my $r_user;
    my $displayname;
    my $to_be_conjugation;

    if (defined $cgi->param('login') && (!Bugzilla->user->id || (trim($cgi->param('login')) != Bugzilla->user->login))) {
        $r_userid = login_to_id(trim($cgi->param('login')));
        if ($r_userid == 0) {
                ThrowUserError('invalid_username', { name => $cgi->param('login') });
        }
        $r_user = Bugzilla::User->new($r_userid);
        $displayname = $r_user->name || $r_user->login;
        $to_be_conjugation = 'is';
    } else {
        $r_user = Bugzilla->user;
        $r_userid = Bugzilla->user->id;
        $displayname = "you";
        $to_be_conjugation = 'are';
    }

    $vars->{'userinfo'} = $r_user;
    $vars->{'displayname'} = $displayname;
    $vars->{'to_be_conjugation'} = $to_be_conjugation;

    my $sec_join = " LEFT JOIN bug_group_map
                            ON bug_group_map.bug_id = bugs.bug_id ";

    if ($user->groups) {
        $sec_join .= "
                AND bug_group_map.group_id NOT IN (" . $user->groups_as_string . ") ";
    }
    $sec_join .= "
            LEFT JOIN cc
                   ON cc.bug_id = bugs.bug_id AND cc.who = " . $user->id;

    my $sec_where = "
        AND bugs.creation_ts IS NOT NULL
        AND ((bug_group_map.group_id IS NULL)
             OR (bugs.reporter_accessible = 1 AND bugs.reporter = $userid)
             OR (bugs.cclist_accessible = 1 AND cc.who IS NOT NULL)
             OR (bugs.assigned_to = $userid) ";

    if (defined $cgi->param('useqacontact')) {
        $sec_where .= "
             OR (bugs.qa_contact = $userid) ";
    }

    my $sec_where_minus_grouping = $sec_where . ")";
    $sec_where .= ") " . $dbh->sql_group_by("bugs.bug_id", 'product, bugs.bug_status, bugs.resolution, bugs.bug_severity, bugs.short_desc');

    my $comments = $dbh->selectrow_array(
        "SELECT COUNT(thetext)
           FROM longdescs
          WHERE who = ?", undef, $r_userid);

    $vars->{'comments'} = $comments;
    my $bugs_closed = $dbh->selectrow_array(
           "SELECT COUNT(bugs.bug_id)
              FROM bugs
        INNER JOIN bugs_activity
                ON bugs.bug_id = bugs_activity.bug_id
             WHERE bugs.bug_status IN ('RESOLVED','CLOSED','VERIFIED')
               AND bugs_activity.added IN ('RESOLVED','CLOSED')
               AND bugs_activity.bug_when =
                     (SELECT MAX(bug_when)
                        FROM bugs_activity ba
                       WHERE ba.added IN ('RESOLVED','CLOSED')
                         AND ba.removed IN ('UNCONFIRMED','REOPENED',
                                            'NEW','ASSIGNED','NEEDINFO')
                         AND ba.bug_id = bugs_activity.bug_id)
               AND bugs_activity.who = ?", undef, $r_userid);

    $vars->{'bugs_closed'} = $bugs_closed;
    my $bugs_reported = $dbh->selectrow_array(
           "SELECT COUNT(DISTINCT bug_id)
              FROM bugs
             WHERE bugs.reporter = ?
               AND NOT (bugs.bug_status = 'RESOLVED' AND 
                        bugs.resolution IN ('DUPLICATE','INVALID','NOTABUG',
                                            'NOTGNOME','INCOMPLETE'))",
           undef, $r_userid);
    $vars->{'bugs_reported'} = $bugs_reported;

    $vars->{'developed_products'} = developed_products($r_user);

    my $sth;
    my @patches;
    # XXX - relies on attachments.status!
    if ($dbh->bz_column_info('attachments', 'status')) {
        $sth = $dbh->prepare("
                SELECT attachments.bug_id, attachments.status as status,
                       attachments.attach_id, products.name as product,
                       attachments.description
                  FROM attachments, bugs, products
                 WHERE attachments.bug_id = bugs.bug_id
                   AND bugs.product_id = products.id
                   AND bugs.bug_status IN ('UNCONFIRMED','NEW','ASSIGNED','REOPENED')
                   AND attachments.submitter_id = ?
                   AND attachments.ispatch='1'
                   AND attachments.isobsolete != '1'
                   AND attachments.status IN ('accepted-commit_after_freeze',
                                          'accepted-commit_now', 'needs-work', 'none',
                                          'rejected', 'reviewed')
              ORDER BY attachments.status");

        $sth->execute($r_userid);
        while (my $patch = $sth->fetchrow_hashref) {
            push(@patches, $patch);
        }
    }
    $vars->{'patches'} = \@patches;

    my @assignedbugs;
    $sth = $dbh->prepare(
           "SELECT bugs.bug_id, products.name AS product, bugs.bug_status,
                   bugs.resolution, bugs.bug_severity, bugs.short_desc
              FROM bugs
                   $sec_join
        INNER JOIN products
                ON bugs.product_id = products.id
             WHERE assigned_to = ?
               AND bug_status IN ('UNCONFIRMED','NEW','ASSIGNED','REOPENED')
                   $sec_where
          ORDER BY bug_id DESC");

    $sth->execute($r_userid);
    while (my $bug = $sth->fetchrow_hashref) {
        push(@assignedbugs, $bug);
    }
    $vars->{'assignedbugs'} = \@assignedbugs;

    my @needinfoassignedbugs;
    $sth = $dbh->prepare(
           "SELECT bugs.bug_id, products.name AS product, bugs.bug_status,
                   bugs.resolution, bugs.bug_severity, bugs.short_desc
              FROM bugs
                   $sec_join
        INNER JOIN products
                ON bugs.product_id = products.id
             WHERE assigned_to = ?
               AND bug_status IN ('NEEDINFO')
                   $sec_where
          ORDER BY bug_id DESC");

    $sth->execute($r_userid);
    while (my $bug = $sth->fetchrow_hashref) {
        push(@needinfoassignedbugs, $bug);
    }
    $vars->{'needinfoassignedbugs'} = \@needinfoassignedbugs;

    my @needinforeporterbugs;
    $sth = $dbh->prepare(
           "SELECT bugs.bug_id, products.name AS product, bugs.bug_status,
                   bugs.resolution, bugs.bug_severity, bugs.short_desc
              FROM bugs
                   $sec_join
        INNER JOIN products
                ON bugs.product_id = products.id
             WHERE reporter=?
               AND bug_status IN ('NEEDINFO')
                   $sec_where
          ORDER BY bug_id DESC");

    $sth->execute($r_userid);
    while (my $bug = $sth->fetchrow_hashref) {
        push(@needinforeporterbugs, $bug);
    }
    $vars->{'needinforeporterbugs'} = \@needinforeporterbugs;

    my @newbugs;
    $sth = $dbh->prepare(
           "SELECT bugs.bug_id, products.name AS product, bugs.bug_status,
                   bugs.resolution, bugs.bug_severity, bugs.short_desc
              FROM bugs
                   $sec_join
        INNER JOIN products
                ON bugs.product_id = products.id
             WHERE reporter = ?
               AND bug_status IN ('UNCONFIRMED','NEW','REOPENED')
                   $sec_where
          ORDER BY bug_id DESC");

    $sth->execute($r_userid);
    while (my $bug = $sth->fetchrow_hashref) {
        push(@newbugs, $bug);
    }
    $vars->{'newbugs'} = \@newbugs;

    my @inprogressbugs;
    $sth = $dbh->prepare(
           "SELECT bugs.bug_id, products.name AS product, bugs.bug_status, bugs.resolution, bugs.bug_severity, bugs.short_desc
              FROM bugs
                   $sec_join
        INNER JOIN products
                ON bugs.product_id = products.id
             WHERE reporter=?
               AND bug_status = 'ASSIGNED'
                   $sec_where
          ORDER BY bug_id DESC");

    $sth->execute($r_userid);
    while (my $bug = $sth->fetchrow_hashref) {
        push(@inprogressbugs, $bug);
    }
    $vars->{'inprogressbugs'} = \@inprogressbugs;

    my @recentlyclosed;
    $sth = $dbh->prepare("
            SELECT bugs.bug_id, products.name AS product, bugs.bug_status, 
                   bugs.resolution, bugs.bug_severity, bugs.short_desc 
              FROM bugs
                   $sec_join
        INNER JOIN products
                ON bugs.product_id = products.id
        INNER JOIN bugs_activity
                ON bugs.bug_id = bugs_activity.bug_id
             WHERE bugs.reporter = ?
               AND bugs_activity.added='RESOLVED'
               AND (bugs.bug_status='RESOLVED' OR bugs.bug_status = 'VERIFIED' 
                    OR bugs.bug_status='CLOSED')
               AND bugs_activity.bug_when >= " . $dbh->sql_date_math('LOCALTIMESTAMP(0)', '-', 7, 'DAY')
                 . $sec_where);

    $sth->execute($r_userid);
    while (my $bug = $sth->fetchrow_hashref) {
        push(@recentlyclosed, $bug);
    }
    $vars->{'recentlyclosed'} = \@recentlyclosed;

    if ($user->in_group('editbugs') && $r_user->login =~ '.*@gnome\.bugs$') {
        my $watcher_ids = $dbh->selectcol_arrayref(
            "SELECT watcher FROM watch WHERE watched = ?",
            undef, $r_userid);

        my @watchers;
        foreach my $watcher_id (@$watcher_ids) {
            my $watcher = new Bugzilla::User($watcher_id);
            push (@watchers, Bugzilla::User::identity($watcher));
        }

        @watchers = sort { lc($a) cmp lc($b) } @watchers;
        $vars->{'watchers'} = \@watchers;
    }

    # XXX: this is just a temporary measure until points get back in a table, it
    # can be done here at not cost as numbers are already collected.
    my $points = log(1 + $comments) / log(10) +
                 log(1 + $bugs_closed) / log(2) + 
                 log(1 + $bugs_reported) / log(2);
    $vars->{'points'} = int($points + 0.5);
}

sub developed_products {
    my $self = shift;

    return [] unless $self->id;

    # Get the list of products
    my $groups = $self->{groups};
    my $group_membership;
    foreach my $group (@$groups) {
         push (@$group_membership,
               substr($group->name, 0, index($group->name, '_developers')))
               if $group->name =~ /_developers$/;
    }

    # return it
    return $group_membership;
}

1;
