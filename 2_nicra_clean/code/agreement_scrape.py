# Author: Andrew Breazeale
# FOIA Extraction
# Last Modified: May 2018
# Purpose: Scrape info from foia files

# install packages <- required once
# pip3 install pandas <- run from terminal

# import packages
import os
import pandas as pd

# paths to foia and .py file
rootdir = "/home/arbreazeale/Dropbox (MIT)/projects/ICRR/Shared Folders/nicra/1_nicra_txt"
savedir = "/home/arbreazeale/Dropbox (MIT)/projects/ICRR/Shared Folders/nicra/2_nicra_clean/output"
os.chdir(rootdir)

# globals
pathlist = []
filelist = []
icrrdata = []

# list of .txt. or .TXT files in working directory
for root, subdirs, files in os.walk(rootdir):
    for file in files:
        if file.endswith('.txt') or file.endswith('.TXT'):
            filelist.append(file)
            filelist.sort()
            pathlist.append(os.path.join(root,file))
            pathlist.sort()

## ========================================================================= ##
##                            HHS FOIA Extraction                            ##
## ========================================================================= ##

# open loop through files
for file in pathlist:
    if '1_nicra_txt/UD' not in file and '1_nicra_txt/UE' not in file:
        with open(file, 'rt', errors = 'ignore') as infile:

            # reset counts for each file
            stopcount_first = None
            startcount_rate = 0
            stopcount_rate = 0
            stopcount_name = 0
            stopcount_phone = 0
            linecount_read = 0

            # reset fields for each file
            readfile = []
            firstline = ''
            filepath = ''
            filename = ''
            agency = ''
            agreement_date = ''
            institution = ''
            city = ''
            state = ''
            zip_code = ''
            telephone = ''
            director = ''

            # filename (for coding)
            filename = file.replace(rootdir,'').replace('/', '')

            # enumerative loop
            for linenum, line in enumerate(infile, 0):

                # setup for extraction loops
                line = line.strip()
                readfile.append(line)

                # stopcount first line
                if stopcount_first == None:
                    if readfile[linenum] == '': continue
                    elif readfile[linenum] != '': stopcount_first = linenum

                # startcount rate info
                if startcount_rate == 0:
                    if 'SECTION I:' in line.upper() and 'SECTION I: FRINGE' not in line:
                        startcount_rate = linenum

                # stopcount rate info
                if 'SECTION I: FRINGE' in line.upper() and linenum > startcount_rate: stopcount_rate = linenum
                if 'SECTION II:' in line.upper() and stopcount_rate == 0: stopcount_rate = linenum

                # stopcount phone number
                if 'TELEPHONE' in line.upper(): stopcount_phone = linenum

                # director
                if '(NAME)' in line.upper(): stopcount_name = linenum

            # filepath
            filepath = file.split('/')
            filepath = filepath[7:]
            filepath = '/'.join(filepath)

            # firstlines
            firstline = readfile[stopcount_first]

            # agreement date
            agreement_date = firstline[-14:-5]
            agreement_date = agreement_date.split('!')[0].strip()

            # institution name
            institution = firstline.split('/')[0]
            separated_inst = institution.split()[1:-1]
            institution = ' '.join(separated_inst)
            for number in ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9']:
                if institution.find(number) != -1:
                    separated_inst = institution.split()[:-1]
                    institution = ' '.join(separated_inst)
            del separated_inst
            del number

            # telephone
            if '(' in readfile[stopcount_phone]:
                getphone = stopcount_phone
            elif '(' in readfile[stopcount_phone - 1]:
                getphone = stopcount_phone - 1
            else:
                getphone = stopcount_phone + 1

            if 'U4060500' in filename:
                telephone = ''
            elif 'Robert' in readfile[getphone]:
                telephone = readfile[getphone + 2]
            elif 'Susan' in readfile[getphone]:
                telephone = readfile[getphone + 2]
            else:
                telephone = readfile[getphone]
            del getphone

            if ':' in telephone: telephone = telephone.split(':')[1]
            if '.' in telephone: telephone = telephone.split('.')[0]
            if 'Telephone Number' in telephone: telephone = telephone.split('Telephone Number')[0]
            if 'Telephone' in telephone: telephone = telephone.split('Telephone')[0]
            if 'x' in telephone: telephone = telephone.split('x')[0]
            telephone = telephone.strip()

            # representative and department info
            getrep = stopcount_phone - 1
            repline = readfile[getrep]

            if ':' not in repline:
                if 'U2016797' in filename or 'U6505497' in filename or 'U6709295' in filename:
                    agency = ''
                    representative = ''
                else:
                    repline = repline.split()
                    agency = repline[0]
                    repline = repline[2:]
                    representative = ' '.join(repline).strip()

            if ':' in repline:
                representative = repline.split(':')[1].strip()
                agency = repline.split(':')[0]
                agency = agency.split()[0].strip()

            del getrep
            del repline

            director = readfile[stopcount_name - 1].strip()

            # city, state, and zip_code
            citystatezip = readfile[stopcount_first + 10]

            for addresses in ['P.O', 'P. O.', 'PO BOX', 'STREET', 'ST.', 'ROAD', 'RD.', 'SUITE', 'STE', 'AVENUE', 'AVE.', 'DRIVE', 'DR.', 'WAY', 'BOULEVARD', 'BLVD', 'HALL', 'BUILDING', 'BLDG', 'FLOOR', 'COURT', 'HIGHWAY', 'HWY', 'PARKWAY', 'PKWY']:
                if addresses in citystatezip.upper(): citystatezip = ''
            del addresses

            if 'The rates approved' in citystatezip: citystatezip = ''
            if citystatezip == '': citystatezip = readfile[stopcount_first + 11]
            if 'The rates approved' in citystatezip: citystatezip = readfile[stopcount_first + 9]
            if citystatezip == '': citystatezip = readfile[stopcount_first +10]

            citystatezip = citystatezip.split('  ')
            city = citystatezip[0]
            citystatezip = ' '.join(citystatezip[1:])

            citystatezip = citystatezip.split()
            if len(citystatezip) == 0:
                state = "-"
                zip_code = "-"
            if len(citystatezip) == 1:
                state = citystatezip[0]
                zip_code = "-"
            if len(citystatezip) >= 2:
                state = citystatezip[0]
                zip_code = citystatezip[1]
            del citystatezip

            # extract rates
            for line in readfile:

                # reset rate fields
                rateline = None
                nextline = None
                rate_type = ''
                effective_from = ''
                effective_to = ''
                location = ''
                applicable = ''
                special_remark = ''
                rate = ''

                # ratelines
                if linecount_read < startcount_rate:
                    linecount_read = linecount_read + 1

                elif linecount_read >= startcount_rate and linecount_read < stopcount_rate:
                    if line.startswith(("FIXED", "FINAL", "PROV.", "PRED.")):

                        # initial line
                        rateline = line.upper().strip()

                        # next line
                        nextline = readfile[linecount_read + 1]
                        nextline = nextline.upper().strip()

                        if "FIXED" not in nextline and "FINAL" not in nextline and "PROV." not in nextline and "PRED." not in nextline and "FOR FISCAL YEAR" not in nextline:
                            if nextline != "USE SAME RATES AND CONDITIONS AS THOSE CITED" and nextline != "":
                                rateline = rateline + " " + nextline

                        rateline = rateline.strip().split()

                        # rate type
                        rate_type = rateline[0]
                        rate_type = rate_type.strip()

                        # effective dates
                        effective_from = rateline[1]
                        effective_to = rateline[2]
                        if effective_to.upper() == 'UNTIL':
                            effective_to = ' '.join(rateline[2:4])

                        # rate
                        rate = rateline[3]
                        if rate.upper() == 'AMENDED': rate = 'USE SAME RATES'
                        if rate.upper() == 'USE': rate = 'USE SAME RATES - NOT UNTIL AMENDED'
                        if '%' in rate: rate = rate.replace('%','')

                        # locations and applicable
                        rateline = ' '.join(rateline).strip().upper()

                        if 'ON SITE' in rateline: rateline = rateline.replace('ON SITE', 'ON-SITE')
                        if 'OFF SITE' in rateline: rateline = rateline.replace('OFF SITE', 'OFF-SITE')
                        if 'ON CAMPUS' in rateline: rateline = rateline.replace('ON CAMPUS', 'ON-CAMPUS')
                        if 'OFF CAMPUS' in rateline: rateline = rateline.replace('OFF CAMPUS', 'OFF-CAMPUS')
                        if '0N SITE' in rateline: rateline = rateline.replace('0N SITE', 'ON-SITE')
                        if '0FF SITE' in rateline: rateline = rateline.replace('0FF SITE', 'OFF-SITE')
                        if '0N CAMPUS' in rateline: rateline = rateline.replace('0N CAMPUS', 'ON-CAMPUS')
                        if '0FF CAMPUS' in rateline: rateline = rateline.replace('0FF CAMPUS', 'OFF-CAMPUS')
                        if 'CANPUS' in rateline: rateline = rateline.replace('CANPUS', 'CAMPUS')

                        for number in ['.1', '.2', '.3', '.4', '.5', '.6', '.7', '.8', '.9', '.0', 'AMENDED']:
                            if number in rateline: rateline = rateline.split(number)
                        del number

                        rateline = rateline[1].strip().split()
                        if len(rateline) == 0:
                            location = ''
                            applicable = ''
                        else:
                            location = rateline[0]
                            applicable = ' '.join(rateline[1:])

                        if location == 'USE':
                            location = ''
                            applicable = ''

                        location = location.strip()
                        applicable = applicable.strip()

                        # write to data
                        writeline = (institution, city, state, zip_code, agreement_date, rate_type, effective_from, effective_to, rate, location, applicable, special_remark, agency, director, representative, telephone, filepath)
                        icrrdata.append(writeline)

                    # advance counter
                    linecount_read = linecount_read + 1

                elif linecount_read >= stopcount_rate:
                    continue

## ========================================================================= ##
##                            USED FOIA Extraction                           ##
## ========================================================================= ##

# open loop through files
for file in pathlist:
    if '1_nicra_txt/UE' in file:
        with open(file, 'rt', errors = 'ignore') as infile:

            # reset counts for each file
            stopcount_first = None
            startcount_rate = 0
            stopcount_rate = 0
            stopcount_name = 0
            stopcount_rep = 0
            stopcount_phone = 0
            linecount_read = 0
            stopcount_address = 0

            # reset fields for each file
            readfile = []
            firstline = ''
            filepath = ''
            filename = ''
            agency = ''
            agreement_date = ''
            institution = ''
            city = ''
            state = ''
            zip_code = ''
            telephone = ''
            director = ''

            # filename (for coding)
            filename = file.replace(rootdir,'').replace('/', '')

            # enumerative loop
            for linenum, line in enumerate(infile, 0):

                # setup for extraction loops
                line = line.strip()
                readfile.append(line)

                # stopcount first line
                if stopcount_first == None:
                    if readfile[linenum] == '': continue
                    elif readfile[linenum] != '': stopcount_first = linenum

                # startcount rate info
                if startcount_rate == 0:
                    if 'SECTION I ' in line.upper() and 'SECTION I: FRINGE' not in line.upper(): startcount_rate = linenum

                # stopcount rate info
                if 'SECTION I ' in line.upper() and linenum > startcount_rate: stopcount_rate = linenum
                if 'SECTION II ' in line.upper() and stopcount_rate == 0: stopcount_rate = linenum

                # stopcount address info
                if 'SECTION IV ' in line.upper(): stopcount_address = linenum

                # stopcount phone number
                if 'TELEPHONE' in line.upper(): stopcount_phone = linenum

                # director
                if 'NAME' in line.upper(): stopcount_name = linenum

                # representative
                if 'NEGOTIATOR' in line.upper(): stopcount_rep = linenum

            # filepath
            filepath = file.split('/')
            filepath = filepath[7:]
            filepath = '/'.join(filepath)

            # firstlines
            firstline = readfile[stopcount_first]

            # agreement date
            agreement_date = firstline[firstline.find('!')-8:firstline.find('!')]
            agreement_date = agreement_date.split()[-1]

            # agency
            agency = 'USED'

            # institution name
            institution = firstline.split('/')[0]
            separated_inst = institution.split()[1:-1]
            institution = ' '.join(separated_inst)
            for number in ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9']:
                if institution.find(number) != -1:
                    separated_inst = institution.split()[:-1]
                    institution = ' '.join(separated_inst)
            del separated_inst

            # telephone
            telephone = readfile[stopcount_phone - 1]
            if 'Negotiator' in telephone:
                telephone = readfile[stopcount_phone]
                telephone = ' '.join(telephone.split()[:-2])

            # director
            director = readfile[stopcount_name-1]

            # representative
            representative = readfile[stopcount_rep -1]
            if "Date" in representative:
                representative = readfile[stopcount_rep]
                representative = ' '.join(representative.split()[:-1])

            # city, state, and zip_code
            citystatezip = readfile[stopcount_address + 5]
            if ',' not in citystatezip:
                citystatezip = readfile[stopcount_address + 6]
            if 'Box' in citystatezip or 'Street' in citystatezip: citystatezip = ''
            if ',' not in citystatezip:
                citystatezip = readfile[stopcount_address + 7]

            citystatezip = citystatezip.split('Room')[0]
            zip_code = citystatezip.split()[-1]
            citystatezip = ' '.join(citystatezip.split()[:-1])
            state = citystatezip.split()[-1]
            if state == 'Jersey' or state == 'Carolina': state = ' '.join(citystatezip.split()[-2:])
            city = citystatezip.split(',')[0]
            del citystatezip

            for line in readfile:

                # reset rate fields
                rateline = None
                rate_type = ''
                effective_from = ''
                effective_to = ''
                location = ''
                applicable = ''
                special_remark = ''
                rate = ''

                if linecount_read < startcount_rate:
                    linecount_read = linecount_read + 1

                elif linecount_read >= startcount_rate and linecount_read < stopcount_rate:
                    if line.upper().startswith(("FIXED", "FINAL", "PRED", "PROV")) and '%' in line:

                        # initial line
                        rateline = line.strip().split()

                        # rate type
                        rate_type = rateline[0]
                        rate_type = rate_type.strip()

                        # effective dates
                        effective_from = rateline[1]
                        effective_to = rateline[2].replace('2000', '00').replace('2001', '01')

                        # rate
                        rate = rateline[3]
                        if '%' in rate: rate = rate.split('%')[0]

                        # location and applicable
                        rateline = ' '.join(rateline)
                        if '1/' in rateline: rateline = rateline.split('1/')[1]
                        if '2/' in rateline: rateline = rateline.split('2/')[1]
                        if '3/' in rateline: rateline = rateline.split('3/')[1]
                        rateline = rateline.strip().upper()
                        if 'ON CAMPUS' in rateline: rateline = rateline.replace('ON CAMPUS', 'ON-CAMPUS')

                        if rateline != '':
                            rateline = rateline.split()
                            location = rateline[0].strip()
                            applicable = ' '.join(rateline[1:]).strip()
                        else:
                            continue

                        # write to data
                        writeline = (institution, city, state, zip_code, agreement_date, rate_type, effective_from, effective_to, rate, location, applicable, special_remark, agency, director, representative, telephone, filepath)
                        icrrdata.append(writeline)

                    # advance counter
                    lincount_read = linecount_read + 1

                elif linecount_read >= stopcount_rate:
                    continue

## ========================================================================= ##
##                            DOD FOIA Extraction                            ##
## ========================================================================= ##

# open loop through files
for file in pathlist:
    if '1_nicra_txt/UD' in file:
        with open(file, 'rt', errors = 'ignore') as infile:

            # reset counts for each file
            stopcount_first = None
            startcount_rate = 0
            stopcount_rate = 0
            stopcount_name = 0
            stopcount_phone = 0
            linecount_read = 0
            stopcount_rep = 0
            stopcount_address = 0

            # reset fields for each file
            readfile = []
            firstline = ''
            filepath = ''
            filename = ''
            agency = ''
            agreement_date = ''
            institution = ''
            city = ''
            state = ''
            zip_code = ''
            telephone = ''
            director = ''

            # filename (for coding)
            filename = file.replace(rootdir,'').replace('/', '')
            
            # enumerative loop
            for linenum, line in enumerate(infile, 0):

                # setup for extraction loops
                line = line.strip()
                readfile.append(line)

                # stopcount first line
                if stopcount_first == None:
                    if readfile[linenum] == '': continue
                    elif readfile[linenum] != '': stopcount_first = linenum

                # startcount rate info
                if startcount_rate == 0:
                    if 'TYPE' in line.upper() and 'RATE' in line.upper() and 'LOCATION' in line.upper():
                        startcount_rate = linenum
                    elif 'SECTION I:' in line.upper():
                        startcount_rate = linenum

                # stopcount rate info
                if stopcount_rate == 0:
                    if startcount_rate > 0:
                        if 'LEAVE BENEFIT RATE' in line.upper():
                            stopcount_rate = linenum
                        elif 'STAFF BENEFIT RATE' in line.upper():
                            stopcount_rate = linenum
                        elif 'FRINGE BENEFIT' in line.upper():
                            stopcount_rate = linenum
                        elif 'DISTRIBUTION BASE' in line.upper():
                            stopcount_rate = linenum
                        elif 'SECTION II' in line.upper():
                            stopcount_rate = linenum

                # stopcount phone number
                if 'TELEPHONE' in line.upper(): stopcount_phone = linenum

                # director
                if 'CONTRACTING' in line.upper(): stopcount_name = linenum

                # representative
                if 'FOR INFORMATION CONCERNING' in line.upper(): stopcount_rep = linenum

                # address
                if stopcount_address == 0:
                    if 'NEGOTIATION AGREEMENT' in line.upper():
                        stopcount_address = linenum
                    elif 'PROVISIONAL RATE AGREEMENT' in line.upper():
                        stopcount_address = linenum
                    elif 'FINAL RATE AGREEMENT' in line.upper():
                        stopcount_address = linenum
                    elif 'UNILATERAL RATE DETERMINATION' in line.upper():
                        stopcount_address = linenum

            # filepath
            filepath = file.split('/')
            filepath = filepath[7:]
            filepath = '/'.join(filepath)

            # firstlines
            firstline = readfile[stopcount_first]

            # agreement_date
            agreement_date = firstline[firstline.find('/')-2:firstline.find('/')+6]
            if agreement_date.strip() == "":
                firstline = firstline + ' ' + readfile[stopcount_first + 1]
                agreement_date = firstline[firstline.find('/')-2:firstline.find('/')+6]
            if agreement_date.strip() == "":
                firstline = firstline + ' ' + readfile[stopcount_first + 2]
                agreement_date = firstline[firstline.find('/')-2:firstline.find('/')+6]

            agreement_date = agreement_date.strip()

            # agency
            agency = 'DOD/ONR'

            # institution name
            institution = firstline.split('/')[0]
            separated_inst = institution.split()[1:-1]
            institution = ' '.join(separated_inst)
            for number in ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9']:
                if institution.find(number) != -1:
                    separated_inst = institution.split()[:-1]
                    institution = ' '.join(separated_inst)
            del separated_inst

            # telephone
            phonecount = -1
            telephone = ''

            while phonecount > -20:
                if '703' not in telephone: telephone = readfile[phonecount]
                phonecount = phonecount - 1

            telephone = telephone[telephone.find('703')-1:telephone.find('703')+13]
            if len(telephone) == 1: telephone = ""

            # director
            directorline = readfile[stopcount_name - 1].strip()
            if len(directorline) == 0:
                directorline = readfile[stopcount_name - 2]
            if 'Name' in directorline:
                directorline = readfile[stopcount_name - 3]
            directorline = directorline.split()

            director = ' '.join(directorline[-3:])
            if '.' not in director: director = ' '.join(director.split()[-2:])
            if 'JR.' in director: director = ' '.join(director.split()[-2:])
            if 'PRESIDENT' in director.upper() or 'PLANNING' in director.upper() or 'FINANCE' in director.upper(): director = ''
            del directorline

            # representative
            repline = readfile[stopcount_rep + 1].strip()
            if repline == '':
                repline = readfile[stopcount_rep + 2]

            if 'OFFICE OF NAVAL' in repline.upper(): repline = readfile[stopcount_rep + 2].strip()
            if 'OFFICE OF NAVAL' in repline.upper(): repline = readfile[stopcount_rep + 3].strip()
            if 'INDIRECT COST' in repline.upper(): repline = readfile[stopcount_rep + 2].strip()

            if '800' in repline: repline = repline.split('800')[0]
            if ' OR ' in repline: repline = repline.split(' OR ')[0]
            if ',' in repline: repline = repline.split(',')[0]
            if 'PHONE' in repline: repline = repline.split('PHONE')[0]
            if 'Phone' in repline: repline = repline.split('Phone')[0]
            if 'E-mail' in repline: repline = repline.split('E-mail')[0]
            if 'E-Mail' in repline: repline = repline.split('E-Mail')[0]
            if '-' in repline: repline = repline.split('-')[0]
            if '(' in repline: repline = repline.split('(')[0]
            if len(repline) >= 21: repline = ''

            representative = repline
            del repline

            # city, state, and zip_code
            citystatezip = readfile[stopcount_address + 3]
            if 'PLAZA' in citystatezip or 'FLOOR' in citystatezip or 'AVENUE' in citystatezip: citystatezip = ''
            if ',' not in citystatezip: citystatezip = readfile[stopcount_address + 4]
            if ',' not in citystatezip: citystatezip = readfile[stopcount_address + 5]
            if ',' not in citystatezip: citystatezip = readfile[stopcount_address + 6]
            if ',' not in citystatezip: citystatezip = readfile[stopcount_address + 7]
            if ',' not in citystatezip: citystatezip = readfile[stopcount_address + 10]
            if ',' not in citystatezip: citystatezip = readfile[stopcount_address + 12]

            city = citystatezip.split(',')[0]
            citystatezip = ' '.join(citystatezip.split(',')[1:]).strip()
            zip_code = citystatezip.split()[-1].strip()
            if len(zip_code) != 10:
                if len(zip_code) != 5:
                    zip_code = ''
            state = citystatezip.replace(zip_code, '').strip()
            del citystatezip

            # extract rates
            for line in readfile:

                # reset rate fields
                rateline = None
                nextline = None
                rate_type = ''
                effective_from = ''
                effective_to = ''
                location = ''
                applicable = ''
                special_remark = ''
                rate = ''

                # ratelines
                if linecount_read < startcount_rate:
                    linecount_read = linecount_read + 1

                elif linecount_read >= startcount_rate and linecount_read < stopcount_rate:
                    if line.upper().startswith(('FIXED', 'FINAL', 'PRED', 'PROV')):

                        # initial line
                        rateline = line.upper().strip()
                        if '%' not in rateline:
                            rateline = ''
                        rateline = rateline.split()

                        # nextlines
                        nextline = readfile[linecount_read + 1]
                        nextline = nextline.upper().strip()
                        if '%' in nextline: nextline = ''
                        nextline = nextline.replace('CAMPIS', 'CAMPUS')

                        # rate type
                        if len(rateline) != 0:
                            rate_type = rateline[0]

                        # effective dates
                        if len(rateline) != 0:
                            effective_from = rateline[1]
                            effective_to = rateline[2]

                            counter = 0
                            while counter < 5:
                                if effective_from.find('-1-') == -1:
                                    if effective_from.find('/') == -1:
                                            effective_from = rateline[counter + 1]
                                            effective_to = rateline[counter + 2]
                                counter = counter + 1

                            del counter

                        if effective_from.strip() == 'EMPF/COE':
                            effective_from = '10/01/01'
                            effective_to = 'UNTIL'

                        if effective_to == 'UNTIL': effective_to = 'UNTIL AMENDED'

                        # rate
                        rateline = ' '.join(rateline).strip().upper()
                        if rateline.count('%') > 1:
                            rate = 'override'
                            rateline = ''
                            nextline = ''
                        if rateline.count('%') == 1 and 'N/A' in rateline:
                            rate = 'override'
                            rateline = ''
                            nextline = ''
                        if len(rateline) != 0:
                            ratesplit = rateline.split('%')[0].split()
                            rate = ratesplit[-1]
                            del ratesplit

                        # location, applicable, and special_remarks

                        ## initial setup
                        rateline = rateline + ' ' + nextline
                        rateline = rateline.replace(effective_from, '').replace(effective_to, '').replace('UNTIL', '').replace('AMENDED', '').replace(rate, '').replace('%', '').replace(rate_type, '').strip()
                        del nextline

                        counter = 0
                        while counter < 20:
                            rateline = rateline.replace('  ', ' ').strip()
                            counter = counter + 1
                        del counter

                        ## bases
                        baselist = ['(A)', '(B)', '(C)', '(D)', '(E)', '(F)', '(G)']
                        for base in baselist:
                            if base in rateline: rateline = rateline.replace(base, '')
                        del baselist
                        del base

                        counter = 0
                        while counter < 20:
                            rateline = rateline.replace('  ', ' ').strip()
                            counter = counter + 1
                        del counter

                        ## standard locations
                        if 'ON CAMPUS' in rateline: rateline = rateline.replace('ON CAMPUS', 'ON-CAMPUS')
                        if 'ONSITE' in rateline: rateline = rateline.replace('ONSITE', 'ON-SITE')
                        if 'OFF CAMPUS' in rateline: rateline = rateline.replace('OFF CAMPUS', 'OFF-CAMPUS')
                        if 'OFF- CAMPUS' in rateline: rateline = rateline.replace('OFF- CAMPUS', 'OFF-CAMPUS')
                        if 'OFFSITE' in rateline: rateline = rateline.replace('OFFSITE', 'OFF-SITE')
                        if 'ON/OFF' in rateline and 'ON/OFF-' not in rateline:
                            rateline = rateline.replace('PROGRAMS', '').replace('ALL FEDERAL', 'ALL FEDERAL PROGRAMS').replace('  ', ' ')
                            rateline = rateline.replace('OFF CAMPUS', 'OFF-CAMPUS')

                        counter = 0
                        while counter < 20:
                            rateline = rateline.replace('  ', ' ').strip()
                            counter = counter + 1
                        del counter

                        locationlist = ['ON/OFF-CAMPUS (1)', 'ON/OFF-CAMPUS (2)', 'OFF-CAMPUS (1)', 'OFF-CAMPUS (2)', 'ON-CAMPUS (1)', 'ON-CAMPUS (2)', 'OFF-CAMPUS', 'ON-CAMPUS']
                        for eachlocation in locationlist:
                            if eachlocation in rateline:
                                location = eachlocation
                                rateline = rateline.replace(eachlocation, '')

                        counter = 0
                        while counter < 20:
                            rateline = rateline.replace('  ', ' ').strip()
                            counter = counter + 1
                        del counter

                        if location != '':
                            if ',' in rateline:
                                rateline = rateline.split(',')
                                applicable = rateline[0].strip()
                                special_remark = rateline[1].strip()
                                rateline = ' '.join(rateline)
                                rateline = ''

                        if location != '':
                            remarklist = ['(EXCEPT JPL)', '- CAPPED (1)', '- UNCAPPED (2)', 'ACADEMIC RESEARCH CENTER', 'ACADEMIC RESEARCH CTR', 'ALL LOCATIONS EXCEPT ARL & HMC', 'ALL LOCATIONS EXCEPT ARL* & HMC**', 'COLLEGE OF AGRICULTURE', 'DENVER RESEARCH INSTITUTE', 'DENVER RESEARCH', 'DRI*', 'DRI', 'GTRI; **', 'GTRI;', 'LDEO (MODIFIED)', 'LDEO', 'LOCATIONS EXCEPT ARL & HMC', 'MODIFIED', 'PHYSICAL SCIENCE LAB', 'WESTCHESTER']
                            for eachremark in remarklist:
                                if eachremark in rateline:
                                    if special_remark != '':
                                        special_remark = special_remark + ', ' + eachremark
                                        rateline = rateline.replace(eachremark, '').replace('  ', ' ').strip()
                                    else:
                                        special_remark = eachremark
                                        rateline = rateline.replace(eachremark, '').replace('  ', ' ').strip()

                            del remarklist
                            del eachremark

                        if location != '':
                            if applicable == '':
                                applicable = rateline
                                rateline = ''


                        ## GTRI
                        remarklist = ['GTRI;', 'GTRI*', 'GTRI']
                        for eachremark in remarklist:
                            if eachremark in rateline:
                                special_remark = eachremark
                                rateline = rateline.replace(eachremark, '').strip().replace('  ',' ')
                        del remarklist
                        del eachremark

                        if 'GTRI' in special_remark:
                            applicablelist = ['OTHER SPONSORED ACTIVITY (1)/(2)', 'ORGANIZED RESEARCH (1)', 'ORGANIZED RESEARCH (2)', 'ALL ACTIVITIES']
                            for eachapplicable in applicablelist:
                                if eachapplicable in rateline:
                                    applicable = eachapplicable
                                    rateline = rateline.replace(eachapplicable, '').strip().replace('  ', ' ')
                            del applicablelist
                            del eachapplicable

                        if 'GTRI' in special_remark:
                            locationlist = ['ATLANTA LAB', 'ARLINGTON LAB', 'HUNTSVILLE LAB', 'ATLANTA', 'ARLINGTON', 'HUNTSVILLE', 'WESTERN ACT', 'FIELD SITES', 'G&A', 'FRINGE (FULL)', 'FRINGE (PARTIAL)']
                            for eachlocation in locationlist:
                                if eachlocation in rateline:
                                    location = eachlocation
                                    rateline = rateline.replace(eachlocation, '').strip().replace('  ', ' ')
                                    rateline = rateline.replace('(S)', '').replace('()', '').replace('(.)', '').replace('  ', ' ').replace('LAB OH', '').strip()

                        if 'GTRI' in special_remark:
                            if 'COST' in rateline and 'MONEY' in rateline:
                                special_remark = special_remark + ', COST OF MONEY'
                                rateline = rateline.replace('COST OF', '').replace('MONEY', '').replace ('  ', ' ').strip()

                            if 'FRINGE' in rateline:
                                if 'PARTIAL' in rateline:
                                    location = 'FRINGE (PARTIAL)'
                                    rateline = rateline.replace('FRINGE', '').replace('(PARTIAL)', '').replace ('  ', ' ').strip()
                                if 'FULL' in rateline:
                                    location = 'FRINGE (FULL)'
                                    rateline = rateline.replace('FRINGE', '').replace('(FULL)', '').replace ('  ', ' ').strip()
                            if 'FIELD' in rateline and 'SITES' in rateline:
                                location = 'FIELD SITES'
                                rateline = rateline.replace('FIELD', '').replace('SITES', '').replace ('  ', ' ').strip()
                            if 'RATE' in rateline: rateline = rateline.replace('RATE', '').replace('  ', ' ')
                            if 'ON' in rateline:
                                location = 'ON-CAMPUS'
                                rateline = ''
                            if 'OFF' in rateline:
                                location = 'OFF-CAMPUS'
                                rateline = ''
                            if 'ALL ACTIVITIES' in rateline:
                                applicable = 'ALL ACTIVITES'
                                rateline = ''

                        counter = 0
                        while counter < 20:
                            rateline = rateline.replace('  ', ' ').strip()
                            counter = counter + 1
                        del counter

                        ## applicables (1st)
                        applicablelist = ['OTHER SPONSORED ACTIVITIES (1)/(2)', 'OTHER SPONSORED ACTIVITY (1)/(2)', 'SPONSORED INSTRUCTION (1)/(2)', 'INSTRUCTION (1)/(2)', 'ALL PROGRAMS (1)', 'ALL PROGRAMS (2)', 'SPONSORED RESEARCH AND OTHER SPONSORED ACTIVITIES', 'SPONSORED RESEARCH AND OTHER SPONSORED', 'ORGANIZED RESEARCH AND OTHER SPONSORED', 'ORGANIZED RESEARCH (1)', 'ORGANIZED RESEARCH (2)', 'AGRICULTURAL RESEARCH', 'ANIMAL CARE', 'SUPERCOMPUTING']
                        for eachapplicable in applicablelist:
                            if eachapplicable in rateline:
                                applicable = eachapplicable
                                rateline = rateline.replace(eachapplicable, '').replace('  ', ' ').strip()
                        del applicablelist
                        del eachapplicable

                        if applicable != '' and rateline != '':

                            if 'PHYSICAL SCIENCE LAB' in rateline:
                                special_remark = 'PHYSICAL SCIENCE LAB'
                                rateline = rateline.replace('PHYSICAL SCIENCE LAB', '').replace('  ', ' ').strip()

                            if 'ON CAMPUS' in rateline:
                                location = 'ON-CAMPUS'
                                rateline = rateline.replace('ON CAMPUS', '').replace('  ', ' ').strip()

                            if 'OFF CAMPUS' in rateline:
                                location = 'OFF-CAMPUS'
                                rateline = rateline.replace('OFF CAMPUS', '').replace('  ', ' ').strip()

                        if applicable != '' and rateline != '':
                            location = rateline
                            rateline = ''

                        ## applicables (2nd)
                        if 'WORKERS' in rateline: rateline = rateline.replace("'", '').replace('=', '').replace('  ', ' ').strip()
                        applicablelist = ['OLD AGE SURVIVORS AND DISABILITY INSURANCE (OASDI)', 'OLD AGE SURVIVORS AND DISABILITY', 'OLD AGE SURVIVORS', 'HEALTH, LIFE AND DENTAL INSURANCE (HLD)', 'HEALTH, LIFE AND DENTAL', 'SOCIAL SECURITY', 'SHIP OPERATIONS', 'POKER FLAT', 'ARSC', 'AMERICAN RUSSIAN CENTER', 'BRANCH COLLEGES', 'INTERNAL OVERHEAD(NAVY)', 'INTERNAL OVERHEAD (NON-NAVY)', 'USE CHARGE - GOVERNMENT PROPERTY', 'TUITION REMISSION', 'INTERNAL OVERHEAD', 'INDIRECT OVERHEAD', 'R&D OVERHEAD', 'COMPLIANCE OVERHEAD', 'AUTHORIZED ABSENCES', 'TERMINATION PAY', 'WORKERS COMPENSATION', 'NON-RETIREMENT FACULTY', 'NO RETIREMENT (*)', 'NO RETIREMENT*', 'TEACHER RETIREMENT', 'STATE RETIREMENT', 'OPTIONAL RETIREMENT', 'RETIREMENT', 'PART-TIME STAFF & PAID STUDENTS', 'FACULTY & STAFF', 'PAID STUDENTS', 'GRADUATE STUDENT', 'PART-TIME STAFF', 'FACULTY', 'STUDENT', 'STAFF', 'TEMPORARY', 'MEDICARE', 'STRATEGIC DEVELOPMENT', 'SUBSIDIARY ADMIN & PROJECT']
                        for eachapplicable in applicablelist:
                            if eachapplicable in rateline:
                                applicable = eachapplicable
                                rateline = rateline.replace(eachapplicable, '').replace('/', '').replace(',', '').replace('  ', ' ').strip()
                                location = rateline.replace('  ', ' ').strip()
                                rateline = rateline.replace(location, '').replace('  ', ' ').strip()
                        del applicablelist
                        del eachapplicable

                        ## organized research
                        if 'ORGANIZED' in rateline and 'RESEARCH' in rateline:
                            if 'AGRICULTURE' in rateline:
                                special_remark = 'AGRICULTURE'
                                rateline = rateline.replace('AGRICULTURE', '')
                            if ',' in rateline: rateline = rateline.replace(',', '')
                            if 'CAMPUS' in rateline:
                                rateline = rateline.replace('ON ', 'ON-CAMPUS ').replace('OFF ', 'OFF-CAMPUS ').replace(' CAMPUS','')
                                rateline = rateline.replace('ORGANIZED', '').replace('RESEARCH', 'ORGANIZED RESEARCH').replace('  ', ' ').strip()
                            applicable = 'ORGANIZED RESEARCH'
                            rateline = rateline.replace('ORGANIZED RESEARCH', '').replace('  ', ' ').strip()
                            location = rateline
                            rateline = rateline.replace(location, '').replace('  ', ' ').strip()

                        ## sponsored
                        if 'SPONSORED' in rateline:
                            if 'OTHER' in rateline:
                                applicable = 'OTHER SPONSORED ACTIVITIES'
                                rateline = rateline.replace('OTHER', '').replace('SPONSORED', '').replace('ACTIVITY', '').replace('ACTIVITIES', '').replace('  ', ' ').replace('  ', ' ').strip()
                            if 'TRAINING' in rateline:
                                applicable = 'SPONSORED TRAINING'
                                rateline = rateline.replace('SPONSORED', '').replace('TRAINING', '').replace('  ', ' ').strip()
                            if 'INSTRUCTION' in rateline:
                                applicable = 'SPONSORED INSTRUCTION'
                                rateline = rateline.replace('SPONSORED', '').replace('INSTRUCTION', '').replace('  ', ' ').strip()
                            if 'ON CAMPUS' in rateline: rateline = 'ON-CAMPUS'
                            if 'OFF CAMPUS' in rateline: rateline = 'OFF-CAMPUS'
                            location = rateline
                            rateline = rateline.replace(location, '').replace('  ', ' ').strip()

                        counter = 0
                        while counter < 20:
                            rateline = rateline.replace('  ', ' ').strip()
                            counter = counter + 1
                        del counter

                        ## finalise
                        if 'ON-SITE' in rateline:
                            location = 'ON-SITE'
                            rateline = rateline.replace(location, '').replace('  ', ' ').strip()
                        if 'OFF-SITE' in rateline:
                            location = 'OFF-SITE'
                            rateline = rateline.replace(location, '').replace('  ', ' ').strip()
                        if 'GEISINGER' in rateline:
                            location = 'GEISINGER CENTER'
                            rateline = rateline.replace(location, '').replace(',', '').replace('  ', ' ').strip()
                            special_remark = rateline
                            rateline = rateline.replace(special_remark, '').replace('  ', ' ').strip()
                        if 'WEIS RESEARCH' in rateline:
                            location = 'WEIS RESEARCH CENTER'
                            rateline = rateline.replace(location, '').replace(',', '').replace('  ', ' ').strip()
                            special_remark = rateline
                            rateline = rateline.replace(special_remark, '').replace('  ', ' ').strip()
                        if 'MERC (*)' in rateline:
                            location = 'MERC (*)'
                            rateline = rateline.replace(location, '').replace('  ', ' ').strip()
                        if 'ALL PROGRAMS' in rateline:
                            applicable = 'ALL PROGRAMS'
                            rateline = rateline.replace(applicable, '').replace('  ', ' ').strip()
                        if 'PERFORMED' in rateline or 'PERFPRMED' in rateline:
                            applicable = 'PROGRAMS PERFORMED OFF-SITE'
                            rateline = rateline.replace('PERFPRMED', '').replace('PERFORMED', '').replace('PROGRAMS', '').replace('  ', ' ')
                        if 'WENTWORTH' in rateline:
                            applicable = rateline
                            rateline = rateline.replace(applicable, '').strip()
                        if 'SI' in rateline:
                            locationlist = ['SI SERC', 'SI NSRC', 'SI']
                            for eachlocation in locationlist:
                                if eachlocation in rateline:
                                    location = eachlocation + ' ' + location
                                    rateline = rateline.replace(location, '').replace('  ', ' ').strip()
                            if 'SI SI' in location: location = location.replace('SI SI', 'SI')
                            location = location.strip()
                            del locationlist
                            del eachlocation
                            rateline = rateline.replace('SI SERC', '').replace('SI NSRC', '').replace('SI', '').replace('*', '').replace('  ', ' ').strip()
                            special_remark = rateline
                            rateline = ''
                        if 'SAO' in rateline:
                            location = 'SAO ' + location
                            rateline = rateline.replace('SAO', '').replace('*', '').replace('  ', ' ').strip()
                            special_remark = rateline
                            rateline = ''
                        if 'FRINGE' in rateline:
                            if 'SAME' in rateline:
                                location = 'ALL'
                                applicable = 'SAME AS BASE'
                                special_remark = 'FRINGE'
                                rateline = ''
                            if 'ALL ACTIVITIES' in rateline:
                                applicable = 'ALL ACTIVITIES'
                                rateline = rateline.replace(applicable, '').replace('  ', ' ').strip()
                                special_remark = rateline
                                rateline = ''
                            if 'ALL' in rateline:
                                location = 'ALL'
                                special_remark = 'FRINGE'
                                rateline = ''
                        if 'OVERHEAD' in rateline:
                            if 'PROGRAMS' in rateline:
                                activity = 'PROGRAMS'
                                rateline = rateline.replace(activity, '').strip()
                            if 'EMPF/COE' in rateline:
                                location = 'EMPF/COE OVERHEAD*'
                                rateline = ''
                        if 'SUB' in rateline:
                            location = 'ALL'
                            applicable = 'ALL PROGRAMS'
                            rateline = 'SUB-AGREEMENT'
                        if 'SAME' in rateline:
                            location = 'ALL'
                            applicable = 'SAME AS BASE'
                            rateline = rateline.replace('ALL','').replace('SAME AS', '').replace('BASE', '').replace('  ', ' ').strip()
                        if 'VALUE' in rateline:
                            location = 'ALL'
                            applicable = 'VALUE ADDED BASE'
                            rateline = rateline.replace('ALL','').replace('VALUE', '').replace('ADDED BASE', '').replace('  ', ' ').strip()
                        if 'ALL ACTIVITIES' in rateline:
                            applicable = 'ALL ACTIVITIES'
                            rateline = rateline.replace(applicable, '').strip()
                        if 'ALL' in rateline:
                            location = 'ALL'
                            rateline = rateline.replace('ALL', '').replace('  ', ' ').strip()
                        if 'SEI' in rateline:
                            location = 'SEI'
                            rateline = ''
                        if 'RESEARCH' in rateline:
                            applicable = 'RESEARCH'
                            rateline = rateline.replace(applicable, '').strip()
                        if location != '' and applicable != '' and rateline != '':
                            special_remark = rateline
                            rateline = ''
                        if rateline != '':
                            special_remark = rateline
                            rateline = ''

                        # write to data
                        writeline = (institution, city, state, zip_code, agreement_date, rate_type, effective_from, effective_to, rate, location, applicable, special_remark, agency, director, representative, telephone, filepath)
                        icrrdata.append(writeline)

                    # advance counter
                    linecount_read = linecount_read + 1

                elif linecount_read >= stopcount_rate:
                    continue

## ========================================================================= ##
##                                Export Data                                ##
## ========================================================================= ##

df = pd.DataFrame(data = icrrdata, columns = ['institution', 'city', 'state', 'zip_code', 'agreement_date', 'rate_type', 'effective_from', 'effective_to', 'rate', 'location', 'applicable', 'special_remark', 'agency', 'director', 'representative', 'telephone', 'filepath'])
os.chdir(savedir)
df.to_csv('nicra_raw.csv')
