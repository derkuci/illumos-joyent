#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or http://www.opensolaris.org/os/licensing.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#
#
# Copyright 2007 Sun Microsystems, Inc.  All rights reserved.
# Use is subject to license terms.
#
#ident	"%Z%%M%	%I%	%E% SMI"
#

include		$(SRC)/Makefile.master

LINTLOG=	../lint.$(MACH).log

PKGARCHIVE=	.
DATAFILES=	copyright prototype_com prototype_$(MACH) postinstall \
		preremove depend checkinstall
DATAFILES_EXT=	prototype_com_ext_usr_bin prototype_com_ext_usr_lib \
		prototype_$(MACH)_ext_usr_bin prototype_$(MACH)_ext_usr_lib
README=		SUNWonld-README
FILES=		$(DATAFILES) $(DATAFILES_EXT) pkginfo
PACKAGE= 	SUNWonld
ROOTONLD=	$(ROOT)/opt/SUNWonld
ROOTREADME=	$(README:%=$(ROOTONLD)/%)

VERDEBUG=	-D
$(INTERNAL_RELEASE_BUILD)VERDEBUG=

CLEANFILES=	$(FILES) awk_pkginfo ../bld_awk_pkginfo $(LINTLOG)
CLOBBERFILES=	$(PACKAGE) $(LINTLOG).bak

../%:		../common/%.ksh
		$(RM) $@
		cp $< $@
		chmod +x $@

$(ROOTONLD)/%:	../common/%
		$(RM) $@
		cp $< $@
		chmod +x $@
