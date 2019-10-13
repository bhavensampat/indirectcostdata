*! Andrew Breazeale
*! NICRA Cleaning for NBER Tasks
*! Requires nicra_cleaned.dta from 2_nicra_clean/output


clear all
version 14
set more off 

/* ------------------------------- Begin Note ------------------------------- // 

	Order of Operations for this file:
	 
	1.	Identify and capture "subinstitutions" of interest. Subinstitutions are
		those institutions that are part of a larger organization that we may 
		wish to consider separately from the larger organization. For example, 
		the agreements for Penn State University includes separate rates for the 
		Hershey Medical Center (HMC) and Penn State as a larger organization. 
		Because HMC receives a large number of grants and has its own ICR rate, 
		we want to separate HMC from Penn State for our analysis.
		 
	2.	Standardize institution names. The agreements do not uniformly use 
		consistent naming conventions for the same institution. The final 
		product of this step is to ensure that each unique institution has a 
		uniquely identifying name in the data. In some cases, this assignment is
		straightforward (e.g., "UNIV. OF TENNESSEE OF MARTIN" and "UNIVERSITY OF 
		TENNESSEE OF MARTIN" are clearly the same institution). In other cases, 
		assignment is not obvious and had to be confirmed using another field or
		by hand (e.g., their were two CHILDREN'S RESEARCH INSTITUTE entries, one
		in Washington, DC and the other in Columbus, OH).
	
	3.	Subset the data. We isolate a set of "important" institutions, which we
		are calling "relevant" institutions. Within those relevant institutions
		we keep the on campus/on site rates. 
		
	4.	Reshape the data and remove overlapping rates. Because the rates are not 
		presented over standardized time frames, we reshape the data so that 
		each row presents a single institution-year-month grouping. Becuase 
		there are some cases where a new agreement comes into effect before the 
		previous agreement expires, we also remove overlaps in the data (i.e., 
		when there exists more than one institution-year-month grouping, we keep 
		the rate associated with the most recent agreement). 

	5.	Add foia2 data. To get a longer panel and broader coverage, we include
		rates from a second HHS foia request. Unlike foia1, we do not have the 
		underlying agreements for the rates, but instead receive a single rate
		per institution per year. Because we do not know which ICR rate HHS 
		provided in the foia2 source and because we use institution-year-month 
		groups for the foia1 data, we use the following method to match foia2
		institution-year pairs to the foia1 institution-year-month rates: 
		
		a.	Expand the foia2 rates to 12 months (starting in January and ending 
			in December of the year given by the foia2 source). 
		b. 	Iteratively lag the rates by one month (starting with no lag) and 
			match to foia1 rates (using institution-year-month groups).
		c.	If the match is perfect (i.e., where there is overlap, the foia2 
			rates perfectly match the foia1 rates), we keep that match. 
		d.	For those matches where the match is not perfect, repeat the process
			for the next iteration of the lag.
	
// -------------------------------- End Note -------------------------------- */


// ========================================================================== //
//                              REPEATED ROUTINE                              //
// ========================================================================== //

/* ------------------------------- Begin Note ------------------------------- // 

	The "trim_subroutine" program performs some simple standardization commands
	on a dataset. Specifically it (1) can convert fields to string (when 
	specified), (2) can standardize field names as lowercase (when specified),
	(3) captializes all string field entries (default), (4) removes all extra
	spaces (leading/trailing and internal) (default), and (5) compress the 
	dataset (default). 

// -------------------------------- End Note -------------------------------- */ 

capture program drop trim_subroutine
program define trim_subroutine

	syntax , [string(string) lower(string)]
	
	ds
	local variables = r(varlist)
	
	if "`string'" == "yes" {
		tostring `variables', replace
	}
	
	if "`lower'" == "yes" {
		rename `variables', lower
	}
	
	foreach variable of local variables {
		capture replace `variable' = itrim(trim(upper(`variable')))
		capture replace `variable' = subinstr(`variable', "–", "-", .)
		label variable `variable' ""
	}
	
	compress

end // programme trim_subroutine


// ========================================================================== //
//                              PRIMARY PROGRAM                               //
// ========================================================================== //

/* ------------------------------- Begin Note ------------------------------- // 

	We perform setup steps (e.g., defining globals mapping to the directory 
	structure) to ensure this code can easily be executed on different machines. 
	
	To execute, the user must change the $basedir global to specify the primary 
	path to their directory. This can be found under the "change this path" 
	header. 
		
// -------------------------------- End Note -------------------------------- */

// ------- setup directory and install external .ado files ------ //

	// ----- clear ----- //
	clear
	macro drop _all

	// ----- ssc ----- //
	capture ssc install filelist, replace

	// ----- change this path ----- //
	if c(username) == "arbreazeale" {
		global basedir "~/Dropbox (MIT)/projects/ICRR/Shared Folders"
	}
	if c(username) == "pazoulay"{
		global basedir "D:/Dropbox (Personal)/ICRR"
	}
	if c(username) == "bhavensampat" {
		global basedir "~/Dropbox/ICRR/nicra"
	}
		
	// ----- leave these paths ----- //
	global nicra "${basedir}/nicra"
	global nicra_txt "${nicra}/1_nicra_txt"
	global nicra_clean "${nicra}/2_nicra_clean"
	global nicra_code "${nicra_clean}/code"
	global nicra_output "${nicra_clean}/output"
	global hhs "${nicra}/3_hhs"
	global nih_dataset "${nicra}/4_nih_dataset"
	global nih_code "${nih_dataset}/code"
	global nih_output "${nih_dataset}/output"
	global byhand "${nicra}/99_byhand"

	// ----- remove output files produced by this .do file ----- //
	local files: dir "${nih_output}" files *
	foreach file of local files {
		rm "${nih_output}/`file'"
	}

	// ----- create log ----- //
	capture log close
	log using "${nih_code}/nih_nicra_cleaning.log", replace

/* ------------------------------- Begin Note ------------------------------- // 

	Operation 01: Identify and capture subinstitutions. 
		
	Each agreement indentifies rate characteristics using the following fields: 
	location, applicable, and special_remark. Depending on the agreement, any 
	one of these fields (or a combination of these fields) may provide 
	information identifying subinstitutions. Because of this, we must consider 
	and change these fields as if they were a single unit. 
	
	To simplify this process for ourselves, we first create "new" fields where 
	we populate the corrected information. We then replace the "old" information 
	with the new information after all the "new" fields have been updated. The 
	benefit of this approach is that we can reuse the same if statement criteria
	when changing each of the fields. 
	
	In some cases, the correct information for the updated field may be remove 
	whatever information originally populated that field. Because of this (and 
	in conjunction with the approach described in the previous paragraph) we 
	create the "flag" fields, which identify all observations that we wish to 
	change (including those where the change amounts to replace field = ""). 
	
	After the changes have been made, we drop the "new" and "flag" fields. 
	
// -------------------------------- End Note -------------------------------- */

// ------- identify and capture the subinstitutions ------- //

	// ----- get data from first .do file output ----- //
	use "${nicra_output}/nicra_cleaned.dta", clear
	
	// ----- create original_institution for concordance ----- //
	gen original_institution = institution
	
	// ----- create new variables ----- //
	gen new_institution = ""
	gen new_location = ""
	gen new_applicable = ""
	gen new_special_remark = ""
	
	// ----- replace new_institution with subinstitutions ----- //
	replace new_institution = "ALBERT EINSTEIN MEDICAL CENTER" if institution == "ALBERT EINSTEIN HEALTHCARE NETWORK" & location == "ALBERT EINSTEIN MEDICAL CENTER" & applicable == "ORGANIZED RESEARCH" & special_remark == ""
	replace new_institution = "ALLEGHENY HEALTH, EDUCATION, AND RESEARCH FOUNDATION" if institution == "ALLEGHENY UNIVERSITY OF THE HEALTH SCIENCES" & city == "PITTSBURGH" & special_remark != "PHILADELPHIA"
	replace new_institution = "ALLEGHENY HEALTH, EDUCATION, AND RESEARCH FOUNDATION" if institution == "ALLEGHENY UNIVERSITY OF THE HEALTH SCIENCES" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "PITTSBURGH"
	replace new_institution = "ALLEGHENY HEALTH, EDUCATION, AND RESEARCH FOUNDATION" if institution == "ALLEGHENY UNIVERSITY OF THE HEALTH SCIENCES" & location == "ON CAMPUS" & applicable == "RESEARCH" & special_remark == "PITTSBURGH"
	replace new_institution = "ANTIOCH UNIVERSITY - LOS ANGELES CAMPUS" if institution == "ANTIOCH UNIVERSITY" & city == "YELLOW SPRINGS" & location == "SOUTHERN CALIFORNIA CAMPUS" & applicable == "ALL PROGRAMS"
	replace new_institution = "ANTIOCH UNIVERSITY - NEW ENGLAND CAMPUS" if institution == "ANTIOCH UNIVERSITY" & city == "YELLOW SPRINGS" & location == "NEW ENGLAND CAMPUS" & applicable == "ALL PROGRAMS"
	replace new_institution = "ANTIOCH UNIVERSITY - SEATTLE CAMPUS" if institution == "ANTIOCH UNIVERSITY" & city == "YELLOW SPRINGS" & location == "SEATTLE CAMPUS" & applicable == "ALL PROGRAMS"
	replace new_institution = "ANTIOCH UNIVERSITY - YELLOW SPRINGS CAMPUS" if institution == "ANTIOCH UNIVERSITY" & city == "YELLOW SPRINGS" & location == "YELLOW SPRINGS CAMPUS" & applicable == "ALL PROGRAMS"
	replace new_institution = "BELMONT BEHAVIORAL HEALTH" if institution == "ALBERT EINSTEIN HEALTHCARE NETWORK" & location == "BELMONT BEHAVIORAL HEALTH" & applicable == "ORGANIZED RESEARCH" & special_remark == ""
	replace new_institution = "BERKSHIRE COMMUNITY COLLEGE" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & city == "BOSTON" & location == "BERKSHIRE" & applicable == "ALL PROGRAMS"
	replace new_institution = "BLANCHETTE ROCKEFELLER NEUROSCIENCE INSTITUTE" if institution == "WEST VIRGINIA UNIVERSITY" & city == "MORGANTOWN" & location == "BLANCHETTE ROCKEFELLER NEUROSCIENCE INSTITUTE" & applicable == "ORGANIZED RESEARCH"
	replace new_institution = "BLOOD SYSTEMS RESEARCH INSTITUTE" if institution == "BLOOD SYSTEMS, INC." & location == "BSRI - SF" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "BRIDGEWATER STATE UNIVERSITY" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "BRIDGEWATER" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "BRISTOL COMMUNITY COLLEGE" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & city == "BOSTON" & location == "BRISTOL" & applicable == "ALL PROGRAMS"
	replace new_institution = "BUNKER HILL COMMUNITY COLLEGE" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & city == "BOSTON" & location == "BUNKER HILL" & applicable == "ALL PROGRAMS"
	replace new_institution = "CALIFORNIA NATIONAL PRIMATE RESEARCH CENTER" if institution == "UNIVERSITY OF CALIFORNIA AT DAVIS" & city == "DAVIS" & location == "CALIFORNIA NATIONAL PRIMATE RESEARCH CENTER" & applicable == "CORE GRANT"
	replace new_institution = "CALIFORNIA NATIONAL PRIMATE RESEARCH CENTER" if institution == "UNIVERSITY OF CALIFORNIA AT DAVIS" & city == "DAVIS" & location == "CALIFORNIA NATIONAL PRIMATE RESEARCH CENTER" & applicable == "RESEARCH"
	replace new_institution = "CALIFORNIA NATIONAL PRIMATE RESEARCH CENTER" if institution == "UNIVERSITY OF CALIFORNIA AT DAVIS" & city == "OAKLAND" & location == "CALIFORNIA REGIONAL PRIMATE CENTER & INSTITUTE OF TOXICOLOGY AND ENVIRONMENTAL HEALTH" & applicable == "RESEARCH"
	replace new_institution = "CAPE COD COMMUNITY COLLEGE" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & city == "BOSTON" & location == "CAPE COD" & applicable == "ALL PROGRAMS"
	replace new_institution = "CHILDREN’S HOSPITAL AND REGIONAL MEDICAL CENTER (SEATTLE)" if institution == "CHILDREN'S HOSPITAL AND REGIONAL MEDICAL CENTER" & city == "SEATTLE" & location == "WESTLAKE" & applicable == "BENCH RESEARCH"
	replace new_institution = "CMG HOSPITAL" if institution == "CASE WESTERN RESERVE UNIVERSITY" & location == "CMG HOSPITAL" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "CONNECTICUT MENTAL HEALTH CENTER" if institution == "YALE UNIVERSITY" & location == "CONNECTICUT MENTAL HEALTH CENTER" & applicable == "ORGANIZED RESEARCH" & special_remark == "AWARDED TO THE STATE OF CONNECTICUT"
	replace new_institution = "CONNECTICUT MENTAL HEALTH CENTER" if institution == "YALE UNIVERSITY" & location == "CONNECTICUT MENTAL HEALTH CENTER" & applicable == "ORGANIZED RESEARCH" & special_remark == "AWARDED TO YALE"
	replace new_institution = "DENVER RESEARCH INSTITUTE" if institution == "UNIVERSITY OF DENVER" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "DENVER RESEARCH INSTITUTE, DOD CONTRACTS BEFORE NOVEMBER 30, 1993 AND NON-DOD INSTRUMENTS"
	replace new_institution = "DENVER RESEARCH INSTITUTE" if institution == "UNIVERSITY OF DENVER" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "DENVER RESEARCH INSTITUTE, DOD CONTRACTS AFTER NOVEMBER 30, 1993"
	replace new_institution = "DENVER RESEARCH INSTITUTE" if institution == "UNIVERSITY OF DENVER" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "DENVER RESEARCH INSTITUTE, DOD CONTRACTS BEFORE NOVEMBER 30, 1993 AND NON-DOD INSTRUMENTS"
	replace new_institution = "FITCHBURG STATE UNIVERSITY" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "FITCHBURG" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "FLORIDA MEDICAL ENTOMOLOGY LABORATORY" if institution == "UNIVERSITY OF FLORIDA" & location == "OFF CAMPUS" & applicable == "AGRICULTURE RESEARCH AND EDUCATION CENTER & FLORIDA MEDICAL ENTOMOLOGY LABORATORY" & special_remark == ""
	replace new_institution = "FLORIDA MEDICAL ENTOMOLOGY LABORATORY" if institution == "UNIVERSITY OF FLORIDA" & location == "ON CAMPUS" & applicable == "AGRICULTURE RESEARCH AND EDUCATION CENTER & FLORIDA MEDICAL ENTOMOLOGY LABORATORY" & special_remark == ""
	replace new_institution = "FROEDTERT MEMORIAL LUTHERAN HOSPITAL" if institution == "MEDICAL COLLEGE OF WISCONSIN" & location == "FROEDTERT MEMORIAL LUTHERAN HOSPITAL" & applicable == "ORGANIZED RESEARCH" & special_remark == ""
	replace new_institution = "FROEDTERT MEMORIAL LUTHERAN HOSPITAL" if institution == "MEDICAL COLLEGE OF WISCONSIN" & location == "FROEDTERT MEMORIAL LUTHERAN HOSPITAL" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "GEISINGER MEDICAL CENTER" if institution == "PENNSYLVANIA STATE UNIVERSITY" & location == "GEISINGER CENTER" & applicable == "-" & special_remark == "HMC (1/2)"
	replace new_institution = "GEISINGER MEDICAL CENTER" if institution == "PENNSYLVANIA STATE UNIVERSITY" & location == "GEISINGER CENTER" & applicable == "RESEARCH" & special_remark == "HERSHEY MEDICAL CENTER"
	replace new_institution = "GEORGE WASHINGTON UNIVERSITY MEDICAL CENTER" if institution == "THE GEORGE WASHINGTON UNIVERSITY" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "MEDICAL CENTER PROGRAMS"
	replace new_institution = "GEORGE WASHINGTON UNIVERSITY MEDICAL CENTER" if institution == "THE GEORGE WASHINGTON UNIVERSITY" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "MEDICAL CENTER"
	replace new_institution = "GEORGE WASHINGTON UNIVERSITY MEDICAL CENTER" if institution == "THE GEORGE WASHINGTON UNIVERSITY" & location == "OFF CAMPUS" & applicable == "OTHER SPONSORED ACTIVITIES" & special_remark == "MEDICAL CENTER"
	replace new_institution = "GEORGE WASHINGTON UNIVERSITY MEDICAL CENTER" if institution == "THE GEORGE WASHINGTON UNIVERSITY" & location == "OFF CAMPUS" & applicable == "RESEARCH" & special_remark == "MEDICAL CENTER"
	replace new_institution = "GEORGE WASHINGTON UNIVERSITY MEDICAL CENTER" if institution == "THE GEORGE WASHINGTON UNIVERSITY" & location == "OFF CAMPUS" & applicable == "SPECIAL PROGRAMS" & special_remark == "MEDICAL CENTER PROGRAMS"
	replace new_institution = "GEORGE WASHINGTON UNIVERSITY MEDICAL CENTER" if institution == "THE GEORGE WASHINGTON UNIVERSITY" & location == "OFF CAMPUS" & applicable == "SPECIAL PROGRAMS" & special_remark == "MEDICAL CENTER PROGRAMS, EXCLUDING MEDICAL CENTER"
	replace new_institution = "GEORGE WASHINGTON UNIVERSITY MEDICAL CENTER" if institution == "THE GEORGE WASHINGTON UNIVERSITY" & location == "OFF CAMPUS" & applicable == "SPECIAL PROGRAMS" & special_remark == "MEDICAL CENTER"
	replace new_institution = "GEORGE WASHINGTON UNIVERSITY MEDICAL CENTER" if institution == "THE GEORGE WASHINGTON UNIVERSITY" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "MEDICAL CENTER PROGRAMS"
	replace new_institution = "GEORGE WASHINGTON UNIVERSITY MEDICAL CENTER" if institution == "THE GEORGE WASHINGTON UNIVERSITY" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "MEDICAL CENTER"
	replace new_institution = "GEORGE WASHINGTON UNIVERSITY MEDICAL CENTER" if institution == "THE GEORGE WASHINGTON UNIVERSITY" & location == "ON CAMPUS" & applicable == "OTHER SPONSORED ACTIVITIES" & special_remark == "MEDICAL CENTER"
	replace new_institution = "GEORGE WASHINGTON UNIVERSITY MEDICAL CENTER" if institution == "THE GEORGE WASHINGTON UNIVERSITY" & location == "ON CAMPUS" & applicable == "RESEARCH" & special_remark == "MEDICAL CENTER"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA INSTITITE OF TECHNOLOGY APPLIED RESEAR CORPORATION" & city == "ATLANTA" & location == "ARLINGTON LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA INSTITITE OF TECHNOLOGY APPLIED RESEAR CORPORATION" & city == "ATLANTA" & location == "ATLANTA LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA INSTITITE OF TECHNOLOGY APPLIED RESEAR CORPORATION" & city == "ATLANTA" & location == "GTRI" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA INSTITITE OF TECHNOLOGY APPLIED RESEAR CORPORATION" & city == "ATLANTA" & location == "HUNTSVILLE LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA INSTITUE OF TECHNOLOGY GEROGIA TECH APPLIED RESEARCH CORPORATION" & city == "ATLANTA" & location == "ARLINGTON LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA INSTITUE OF TECHNOLOGY GEROGIA TECH APPLIED RESEARCH CORPORATION" & city == "ATLANTA" & location == "ATLANTA LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA INSTITUE OF TECHNOLOGY GEROGIA TECH APPLIED RESEARCH CORPORATION" & city == "ATLANTA" & location == "HUNTSVILLE LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA INSTITUE OF TECHNOLOGY GEROGIA TECH APPLIED RESEARCH CORPORATION" & city == "ATLANTA" & location == "WESTERN ACT" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA INSTITUTE OF TECHNOLOGY GEORGIA TECH APPLIED RESEARCH CORPORATION" & city == "ATLANTA" & location == "ARLINGTON LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA INSTITUTE OF TECHNOLOGY GEORGIA TECH APPLIED RESEARCH CORPORATION" & city == "ATLANTA" & location == "ATLANTA LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA INSTITUTE OF TECHNOLOGY GEORGIA TECH APPLIED RESEARCH CORPORATION" & city == "ATLANTA" & location == "HUNTSVILLE LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA INSTITUTE OF TECHNOLOGY GEORGIA" & city == "ATLANTA" & location == "ARLINGTON LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA INSTITUTE OF TECHNOLOGY GEORGIA" & city == "ATLANTA" & location == "ATLANTA LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA INSTITUTE OF TECHNOLOGY GEORGIA" & city == "ATLANTA" & location == "HUNTSVILLE LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA INSTITUTE OF TECHNOLOGY GEORGIA" & city == "ATLANTA" & location == "WESTERN ACT" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA TECH APPLIED RESEARCH CORPORATION" & city == "ATLANTA" & location == "ARLINGTON LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA TECH APPLIED RESEARCH CORPORATION" & city == "ATLANTA" & location == "ATLANTA LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEORGIA TECH APPLIED RESEARCH CORPORATION" & city == "ATLANTA" & location == "HUNTSVILLE LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEROGIA INSTITUTE OF TECHNOLOGY GEORGIA TECH APPLIED RESEARCH CORPORATION" & city == "ATLANTA" & location == "ARLINGTON LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEROGIA INSTITUTE OF TECHNOLOGY GEORGIA TECH APPLIED RESEARCH CORPORATION" & city == "ATLANTA" & location == "ATLANTA LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GEORGIA INSTITUTE OF TECHNOLOGYY" if institution == "GEROGIA INSTITUTE OF TECHNOLOGY GEORGIA TECH APPLIED RESEARCH CORPORATION" & city == "ATLANTA" & location == "HUNTSVILLE LAB" & applicable == "ALL ACTIVITIES"
	replace new_institution = "GREENFIELD COMMUNITY COLLEGE" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & city == "BOSTON" & location == "GREENFIELD" & applicable == "ALL PROGRAMS"
	replace new_institution = "HARBORVIEW MEDICAL CENTER" if institution == "UNIVERSITY OF WASHINGTON" & location == "HARBORVIEW MEDICAL CENTER" & applicable == "-" & special_remark == ""
	replace new_institution = "HARVARD MEDICAL SCHOOL" if institution == "HARVARD UNIVERSITY SCHOOL OF PUBLIC HEALTH" & location == "MEDICAL SCHOOL AND AFFILIATED HOSPITAL" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "HARVARD MEDICAL SCHOOL" if institution == "HARVARD UNIVERSITY SCHOOL OF PUBLIC HEALTH" & location == "PRIMATE CENTER" & applicable == "CORE GRANT" & special_remark == ""
	replace new_institution = "HARVARD MEDICAL SCHOOL" if institution == "HARVARD UNIVERSITY SCHOOL OF PUBLIC HEALTH" & location == "PRIMATE CENTER" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "HARVARD MEDICAL SCHOOL" if institution == "HARVARD UNIVERSITY" & location == "MEDICAL SCHOOL AND AFFILIATED HOSPITAL" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "HARVARD MEDICAL SCHOOL" if institution == "HARVARD UNIVERSITY" & location == "MEDICAL SCHOOL" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "HARVARD MEDICAL SCHOOL" if institution == "HARVARD UNIVERSITY" & location == "PRIMATE CENTER" & applicable == "CORE GRANT" & special_remark == ""
	replace new_institution = "HARVARD MEDICAL SCHOOL" if institution == "HARVARD UNIVERSITY" & location == "PRIMATE CENTER" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "HARVARD UNIVERSITY SCHOOL OF PUBLIC HEALTH" if institution == "HARVARD MEDICAL SCHOOL" & location == "SCHOOL OF PUBLIC HEALTH" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "HARVARD UNIVERSITY SCHOOL OF PUBLIC HEALTH" if institution == "HARVARD UNIVERSITY" & location == "SCHOOL OF PUBLIC HEALTH" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "HERSHEY MEDICAL CENTER" if institution == "PENNSYLVANIA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "RESEARCH" & special_remark == "HERSHEY MEDICAL CENTER"
	replace new_institution = "HERSHEY MEDICAL CENTER" if institution == "PENNSYLVANIA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "RESEARCH" & special_remark == "HMC"
	replace new_institution = "HERSHEY MEDICAL CENTER" if institution == "PENNSYLVANIA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "RESEARCH" & special_remark == "HERSHEY MEDICAL CENTER"
	replace new_institution = "HERSHEY MEDICAL CENTER" if institution == "PENNSYLVANIA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "RESEARCH" & special_remark == "HMC"
	replace new_institution = "HERSHEY MEDICAL CENTER" if institution == "PENNSYLVANIA STATE UNIVERSITY" & location == "WEIS RESEARCH CENTER" & applicable == "-" & special_remark == "HMC"
	replace new_institution = "HERSHEY MEDICAL CENTER" if institution == "THE PENNSYLVANIA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "RESEARCH" & special_remark == "HMC"
	replace new_institution = "HERSHEY MEDICAL CENTER" if institution == "THE PENNSYLVANIA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "RESEARCH" & special_remark == "HMC"
	replace new_institution = "HOLYOKE COMMUNITY COLLEGE" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & city == "BOSTON" & location == "HOLYOKE" & applicable == "ALL PROGRAMS"
	replace new_institution = "INDIANA UNIVERSITY HOSPITAL" if institution == "INDIANA UNIVERSITY" & city == "BLOOMINGTON" & location == "HOSPITAL" & applicable == "GENERAL CLINICAL RESEARCH CENTER"
	replace new_institution = "INDIANA UNIVERSITY HOSPITAL" if institution == "INDIANA UNIVERSITY" & city == "BLOOMINGTON" & location == "INDIANA UNIVERSITY HOSPITAL" & applicable == "GENERAL CLINICAL RESEARCH CENTER"
	replace new_institution = "INSTITUTE FOR BASIC RESEARCH" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC." & location == "INSTITUTE FOR BASIC RESEARCH" & applicable == "-" & special_remark == ""
	replace new_institution = "INSTITUTE FOR BASIC RESEARCH" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC." & location == "INSTITUTE FOR BASIC RESEARCH" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "KLINE RESEARCH CENTER" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC." & location == "KLINE RESEARCH CENTER" & applicable == "-" & special_remark == ""
	replace new_institution = "KLINE RESEARCH CENTER" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC." & location == "KLINE RESEARCH CENTER" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "LAMONT-DOHERTY EARTH OBSERVATORY" if institution == "COLUMBIA UNIVERSITY" & city == "NEW YORK" & location == "LDEO OFF CAMPUS" & applicable == "RESEARCH"
	replace new_institution = "LAMONT-DOHERTY EARTH OBSERVATORY" if institution == "COLUMBIA UNIVERSITY" & city == "NEW YORK" & location == "LDEO ON CAMPUS" & applicable == "RESEARCH"
	replace new_institution = "LOUISIANA STATE UNIVERSITY AGRICULTURAL CENTER" if institution == "LOUISIANA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "AGRICULTURE EXPERIMENT STATION" & special_remark == ""
	replace new_institution = "LOUISIANA STATE UNIVERSITY AGRICULTURAL CENTER" if institution == "LOUISIANA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "AGRICULTURE RESEARCH CENTER" & special_remark == ""
	replace new_institution = "LOUISIANA STATE UNIVERSITY AGRICULTURAL CENTER" if institution == "LOUISIANA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "AGRICULTURE EXPERIMENT STATION" & special_remark == ""
	replace new_institution = "LOUISIANA STATE UNIVERSITY AGRICULTURAL CENTER" if institution == "LOUISIANA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "AGRICULTURE RESEARCH CENTER" & special_remark == ""
	replace new_institution = "MASSACHUSETTS BAY COMMUNITY COLLEGE" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & city == "BOSTON" & location == "MASSACHUSETTS BAY" & applicable == "ALL PROGRAMS"
	replace new_institution = "MASSACHUSETTS COLLEGE OF ART AND DESIGN" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "COLLEGE OF ART" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "MASSACHUSETTS COLLEGE OF LIBERAL ARTS" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "COLLEGE OF LIBERAL ARTS" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "MASSACHUSETTS COLLEGE OF LIBERAL ARTS" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "NORTH ADAMS" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "MASSACHUSETTS MARITIME ACADEMY" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "MARITIME ACADEMY" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "MASSASOIT COMMUNITY COLLEGE" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & city == "BOSTON" & location == "MASSASOIT" & applicable == "ALL PROGRAMS"
	replace new_institution = "MEDSTAR HEALTH - HARBOR HOSPITAL" if institution == "MEDSTAR RESEARCH INSTITUTE" & city == "HYATTSVILLE" & location == "HARBOR HOSPITAL" & applicable == "NIA"
	replace new_institution = "METROHEALTH MEDICAL CENTER" if institution == "CASE WESTERN RESERVE UNIVERSITY" & location == "METROHEALTH MEDICAL CENTER" & applicable == "ORGANIZED RESEARCH" & special_remark == ""
	replace new_institution = "MIDDLESEX COMMUNITY COLLEGE" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & city == "BOSTON" & location == "MIDDLESEX" & applicable == "ALL PROGRAMS"
	replace new_institution = "MILWAUKEE REGIONAL MEDICAL CENTER" if institution == "MEDICAL COLLEGE OF WISCONSIN" & city == "MILWAUKEE" & location == "MILWAUKEE COUNTY MEDICAL COMPLEX HOSPITAL" & applicable == "RESEARCH"
	replace new_institution = "MOSS REHABILITATION HOSPITAL" if institution == "ALBERT EINSTEIN HEALTHCARE NETWORK" & location == "MOSS REHABILITATION HOSPITAL" & applicable == "ORGANIZED RESEARCH" & special_remark == ""
	replace new_institution = "MT. WACHUSETT COMMUNITY COLLEGE" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & city == "BOSTON" & location == "MT. WACHUSETT" & applicable == "ALL PROGRAMS"
	replace new_institution = "NEW YORK PSYCHIATRIC INSTITUTE" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC." & location == "NEW YORK PSYCHIATRIC INSTITUTE" & applicable == "-" & special_remark == ""
	replace new_institution = "NEW YORK PSYCHIATRIC INSTITUTE" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC." & location == "NEW YORK PSYCHIATRIC INSTITUTE" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "NEW YORK UNIVERSITY SCHOOL OF MEDICINE" if institution == "NEW YORK UNIVERSITY MEDICAL CENTER" & location == "ALL LOCATIONS" & applicable == "GENERAL CLINICAL RESEARCH CENTER" & special_remark == "SCHOOL OF MEDICINE"
	replace new_institution = "NEW YORK UNIVERSITY SCHOOL OF MEDICINE" if institution == "NEW YORK UNIVERSITY MEDICAL CENTER" & location == "ALL LOCATIONS" & applicable == "RESEARCH & REGIONAL MEDICAL PROGRAM" & special_remark == "SCHOOL OF MEDICINE"
	replace new_institution = "NEW YORK UNIVERSITY SCHOOL OF MEDICINE" if institution == "NEW YORK UNIVERSITY MEDICAL CENTER" & location == "OFF SITE" & applicable == "RESEARCH" & special_remark == "SCHOOL OF MEDICINE"
	replace new_institution = "NEW YORK UNIVERSITY SCHOOL OF MEDICINE" if institution == "NEW YORK UNIVERSITY MEDICAL CENTER" & location == "ON SITE" & applicable == "RESEARCH" & special_remark == "SCHOOL OF MEDICINE"
	replace new_institution = "NORTH ESSEX COMMUNITY COLLEGE" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & city == "BOSTON" & location == "NORTH ESSEX" & applicable == "ALL PROGRAMS"
	replace new_institution = "NORTH SHORE COMMUNITY COLLEGE" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & city == "BOSTON" & location == "NORTH SHORE" & applicable == "ALL PROGRAMS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT OKLAHOMA CITY" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "OKLAHOMA CITY CAMPUS, DOD CONTRACTS AFTER 30 NOVEMBER 1993"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT OKLAHOMA CITY" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "OKLAHOMA CITY CAMPUS, DOD CONTRACTS BEFORE 30 NOVEMBER 1993 AND NON-DOD INSTRUMENTS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT OKLAHOMA CITY" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "OKLAHOMA CITY CAMPUS, DOD CONTRACTS AFTER 30 NOVEMBER 1993"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT OKLAHOMA CITY" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "OKLAHOMA CITY CAMPUS, DOD CONTRACTS BEFORE 30 NOVEMBER 1993 AND NON-DOD INSTRUMENTS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT OKMULGEE" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "OKMULGEE CAMPUS, DOD CONTRACTS AFTER 30 NOVEMBER 1993"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT OKMULGEE" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "OKMULGEE CAMPUS, DOD CONTRACTS BEFORE 30 NOVEMBER 1993 AND NON-DOD INSTRUMENTS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT OKMULGEE" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "OKMULGEE CAMPUS, DOD CONTRACTS AFTER 30 NOVEMBER 1993"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT OKMULGEE" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "OKMULGEE CAMPUS, DOD CONTRACTS BEFORE 30 NOVEMBER 1993 AND NON-DOD INSTRUMENTS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "EXTENSION & PUBLIC SERVICE" & special_remark == "STILLWATER CAMPUS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "EXTENSION & PUBLIC SERVICE" & special_remark == "STILLWATER CAMPUS, DOD CONTRACTS AFTER 30 NOVEMBER 1993"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "EXTENSION & PUBLIC SERVICE" & special_remark == "STILLWATER CAMPUS, DOD CONTRACTS BEFORE 30 NOVEMBER 1993 AND NON-DOD INSTRUMENTS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "INSTRUCTION" & special_remark == "STILLWATER CAMPUS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "INSTRUCTION" & special_remark == "STILLWATER CAMPUS, DOD CONTRACTS AFTER 30 NOVEMBER 1993"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "INSTRUCTION" & special_remark == "STILLWATER CAMPUS, DOD CONTRACTS BEFORE 30 NOVEMBER 1993 AND NON-DOD INSTRUMENTS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "RESEARCH" & special_remark == "STILLWATER CAMPUS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "RESEARCH" & special_remark == "STILLWATER CAMPUS, DOD CONTRACTS AFTER 30 NOVEMBER 1993"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "RESEARCH" & special_remark == "STILLWATER CAMPUS, DOD CONTRACTS BEFORE 30 NOVEMBER 1993 AND NON-DOD INSTRUMENTS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "EXTENSION & PUBLIC SERVICE" & special_remark == "STILLWATER CAMPUS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "EXTENSION & PUBLIC SERVICE" & special_remark == "STILLWATER CAMPUS, DOD CONTRACTS AFTER 30 NOVEMBER 1993"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "EXTENSION & PUBLIC SERVICE" & special_remark == "STILLWATER CAMPUS, DOD CONTRACTS BEFORE 30 NOVEMBER 1993 AND NON-DOD INSTRUMENTS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "INSTRUCTION" & special_remark == "STILLWATER CAMPUS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "INSTRUCTION" & special_remark == "STILLWATER CAMPUS, DOD CONTRACTS AFTER 30 NOVEMBER 1993"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "INSTRUCTION" & special_remark == "STILLWATER CAMPUS, DOD CONTRACTS BEFORE 30 NOVEMBER 1993 AND NON-DOD INSTRUMENTS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "RESEARCH" & special_remark == "STILLWATER CAMPUS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "RESEARCH" & special_remark == "STILLWATER CAMPUS, DOD CONTRACTS AFTER 30 NOVEMBER 1993"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT STILLWATER" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "RESEARCH" & special_remark == "STILLWATER CAMPUS, DOD CONTRACTS BEFORE 30 NOVEMBER 1993 AND NON-DOD INSTRUMENTS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT TULS" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "TULSA CAMPUS, DOD CONTRACTS BEFORE 30 NOVEMBER 1993 AND NON-DOD INSTRUMENTS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT TULSA" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "TULSA CAMPUS, DOD CONTRACTS AFTER 30 NOVEMBER 1993"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT TULSA" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "TULSA CAMPUS, DOD CONTRACTS BEFORE 30 NOVEMBER 1993 AND NON-DOD INSTRUMENTS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY AT TULSA" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "TULSA CAMPUS, DOD CONTRACTS AFTER 30 NOVEMBER 1993"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY CENTER FOR HEALTH SCIENCES" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "COLLEGE OF OSTEOPATHIC MEDICINE, DOD CONTRACTS AFTER 30 NOVEMBER 1993"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY CENTER FOR HEALTH SCIENCES" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "COLLEGE OF OSTEOPATHIC MEDICINE, DOD CONTRACTS BEFORE 30 NOVEMBER 1993 AND NON-DOD INSTRUMENTS"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY CENTER FOR HEALTH SCIENCES" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "COLLEGE OF OSTEOPATHIC MEDICINE, DOD CONTRACTS AFTER 30 NOVEMBER 1993"
	replace new_institution = "OKLAHOMA STATE UNIVERSITY CENTER FOR HEALTH SCIENCES" if institution == "OKLAHOMA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "COLLEGE OF OSTEOPATHIC MEDICINE, DOD CONTRACTS BEFORE 30 NOVEMBER 1993 AND NON-DOD INSTRUMENTS"
	replace new_institution = "OREGON NATIONAL PRIMATE RESEARCH CENTER" if institution == "OREGON HEALTH AND SCIENCE UNIVERSITY" & city == "PORTLAND" & location == "OREGON NATIONAL PRIMATE RESEARCH CENTER" & applicable == "CORE GRANT"
	replace new_institution = "OREGON NATIONAL PRIMATE RESEARCH CENTER" if institution == "OREGON HEALTH AND SCIENCE UNIVERSITY" & city == "PORTLAND" & location == "OREGON NATIONAL PRIMATE RESEARCH CENTER" & applicable == "RESEARCH"
	replace new_institution = "OREGON NATIONAL PRIMATE RESEARCH CENTER" if institution == "OREGON HEALTH SCIENCES UNIVERSITY" & location == "OREGON NATIONAL PRIMATE RESEARCH CENTER" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "OREGON NATIONAL PRIMATE RESEARCH CENTER" if institution == "OREGON HEALTH SCIENCES UNIVERSITY" & location == "OREGON NATIONAL PRIMATE RESEARCH CENTER" & applicable == "CORE GRANT" & special_remark == ""
	replace new_institution = "OREGON NATIONAL PRIMATE RESEARCH CENTER" if institution == "OREGON HEALTH SCIENCES UNIVERSITY" & location == "OREGON NATIONAL PRIMATE RESEARCH CENTER" & applicable == "RESEARCH & GENERAL CLINICAL RESEARCH CENTER" & special_remark == ""
	replace new_institution = "OREGON NATIONAL PRIMATE RESEARCH CENTER" if institution == "OREGON HEALTH SCIENCES UNIVERSITY" & location == "OREGON NATIONAL PRIMATE RESEARCH CENTER" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "QUINSIGAMOND COMMUNITY COLLEGE" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & city == "BOSTON" & location == "QUINSIGAMOND" & applicable == "ALL PROGRAMS"
	replace new_institution = "ROSENSTIEL SCHOOL OF MARINE AND ATMOSPHERIC SCIENCE" if institution == "UNIVERSITY OF MIAMI" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "ROSENSTIEL SCHOOL OF MARINE AND ATMOSPHERIC SCIENCE"
	replace new_institution = "ROSENSTIEL SCHOOL OF MARINE AND ATMOSPHERIC SCIENCE" if institution == "UNIVERSITY OF MIAMI" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "ROSENSTIEL SCHOOL OF MARINE AND ATMOSPHERIC SCIENCE"
	replace new_institution = "ROSENSTIEL SCHOOL OF MARINE AND ATMOSPHERIC SCIENCE" if institution == "UNIVERSITY OF MIAMI" & location == "ON CAMPUS" & applicable == "RESEARCH" & special_remark == "ROSENSTIEL SCHOOL OF MARINE AND ATMOSPHERIC SCIENCE"
	replace new_institution = "ROSWELL PARK CANCER INSTITUTE" if institution == "HEALTH RESEARCH, INC." & location == "ROSWELL PARK MEMORIAL INSTITUTE" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "ROXBURY COMMUNITY COLLEGE" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & city == "BOSTON" & location == "ROXBURY" & applicable == "ALL PROGRAMS"
	replace new_institution = "SALEM STATE UNIVERSITY" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "SALEM" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "SCRIPPS RESEARCH INSTITUTE - CALIFORNIA" if institution == "SCRIPPS RESEARCH INSTITUTE" & location == "CALIFORNIA" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "SCRIPPS RESEARCH INSTITUTE - FLORIDA" if institution == "SCRIPPS RESEARCH INSTITUTE" & location == "FLORIDA" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "SMITHSONIAN ASTROPHYSICAL OBSERVATORY" if institution == "SMITHSONIAN INSTITUTION" & location == "ON SITE" & applicable == "ALL PROGRAMS" & special_remark == "CENTRAL ENGINEERING, SMITHSONIAN ASTROPHYSICAL OBSERVATORY"
	replace new_institution = "SMITHSONIAN ASTROPHYSICAL OBSERVATORY" if institution == "SMITHSONIAN INSTITUTION" & location == "ON SITE" & applicable == "ALL PROGRAMS" & special_remark == "DIRECT OPERATING, SMITHSONIAN ASTROPHYSICAL OBSERVATORY"
	replace new_institution = "SMITHSONIAN ASTROPHYSICAL OBSERVATORY" if institution == "SMITHSONIAN INSTITUTION" & location == "ON SITE" & applicable == "ALL PROGRAMS" & special_remark == "G&A, SMITHSONIAN ASTROPHYSICAL OBSERVATORY"
	replace new_institution = "SMITHSONIAN ASTROPHYSICAL OBSERVATORY" if institution == "SMITHSONIAN INSTITUTION" & location == "ON SITE" & applicable == "ALL PROGRAMS" & special_remark == "MATERIAL OVERHEAD, SMITHSONIAN ASTROPHYSICAL OBSERVATORY"
	replace new_institution = "SMITHSONIAN ENVIRONMENTAL RESEARCH CENTER" if institution == "SMITHSONIAN INSTITUTION" & location == "ON SITE" & applicable == "ALL PROGRAMS" & special_remark == "SERC CORE SUPPORT, SMITHSONIAN ENVIRONMENTAL RESEARCH CENTER"
	replace new_institution = "SMITHSONIAN NATIONAL SCIENCE RESEOURCE CENTER" if institution == "SMITHSONIAN INSTITUTION" & location == "ON SITE" & applicable == "ALL PROGRAMS" & special_remark == "INDIRECT CORE, NATIONAL SCIENCE RESOURCE CENTER"
	replace new_institution = "SMITHSONIAN NATIONAL SCIENCE RESEOURCE CENTER" if institution == "SMITHSONIAN INSTITUTION" & location == "ON SITE" & applicable == "ALL PROGRAMS" & special_remark == "NRSC CORE SUPPORT, NATIONAL SCIENCE RESOURCE CENTER"
	replace new_institution = "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY AT NEW ORLEANS" if institution == "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "NEW ORLEANS CAMPUS"
	replace new_institution = "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY AT BATON ROUGE" if institution == "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "BATON ROUGE CAMPUS"
	replace new_institution = "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY AT SHREVEPORT-BOSSIER CITY" if institution == "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "SHREVEPORT BOSSIER CITY CAMPUS"
	replace new_institution = "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY AT SHREVEPORT-BOSSIER CITY" if institution == "SOUTHERN UNIVERSITY" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "SHREVEPORT BOSSIER CITY CAMPUS"
	replace new_institution = "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY AT NEW ORLEANS" if institution == "SOUTHERN UNIVERSITY" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "NEW ORLEANS CAMPUS"
	replace new_institution = "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY AT BATON ROUGE" if institution == "SOUTHERN UNIVERSITY" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "BATON ROUGE CAMPUS"
	replace new_institution = "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY AT NEW ORLEANS" if institution == "SOUTHERN UNIVERSITY" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "NEW ORLEANS CAMPUS"
	replace new_institution = "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY AT SHREVEPORT-BOSSIER CITY" if institution == "SOUTHERN UNIVERSITY" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "SHREVEPORT BOSSIER CITY CAMPUS"
	replace new_institution = "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY AT BATON ROUGE" if institution == "SOUTHERN UNIVERSITY" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "BATON ROUGE CAMPUS"
	replace new_institution = "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY AT BATON ROUGE" if institution == "SOUTHERN UNIVERSITY" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "BATON ROUGE CAMPUS"
	replace new_institution = "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY AT SHREVEPORT-BOSSIER CITY" if institution == "SOUTHERN UNIVERSITY" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "SHREVEPORT BOSSIER CITY CAMPUS"
	replace new_institution = "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY AT BATON ROUGE" if institution == "SOUTHERN UNIVERSITY" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "BATON ROUGE CAMPUS"
	replace new_institution = "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY AT NEW ORLEANS" if institution == "SOUTHERN UNIVERSITY" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "NEW ORLEANS CAMPUS"
	replace new_institution = "SOUTHERN UNIVERSITY AND AGRICULTURAL AND MECHANICAL UNIVERSITY AT SHREVEPORT-BOSSIER CITY" if institution == "SOUTHERN UNIVERSITY" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "SHREVEPORT BOSSIER CITY CAMPUS"
	replace new_institution = "SPRINGFIELD COMMUNITY COLLEGE" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & city == "BOSTON" & location == "SPRINGFIELD" & applicable == "ALL PROGRAMS"
	replace new_institution = "SUNSET PARK FAMILY HEALTH CENTER" if institution == "LUTHERAN MEDICAL CENTER" & city == "BROOKLYN" & location == "ALL LOCATIONS" & applicable == "SUNSET PARK FAMILY HEALTH CENTER"
	replace new_institution = "TUFTS-NEW ENGLAND MEDICAL CENTER" if institution == "TUFTS UNIVERSITY" & location == "OFF CAMPUS" & applicable == "OTHER SPONSORED PROGRAMS" & special_remark == "HEALTH SCIENCES (BOSTON AND GRAFTON)"
	replace new_institution = "TUFTS-NEW ENGLAND MEDICAL CENTER" if institution == "TUFTS UNIVERSITY" & location == "OFF CAMPUS" & applicable == "OTHER SPONSORED PROGRAMS" & special_remark == "HEALTH SCIENCES CAMPUS (BOSTON & GRAFTON)"
	replace new_institution = "TUFTS-NEW ENGLAND MEDICAL CENTER" if institution == "TUFTS UNIVERSITY" & location == "OFF CAMPUS" & applicable == "RESEARCH" & special_remark == "HEALTH SCIENCES (BOSTON AND GRAFTON)"
	replace new_institution = "TUFTS-NEW ENGLAND MEDICAL CENTER" if institution == "TUFTS UNIVERSITY" & location == "OFF CAMPUS" & applicable == "RESEARCH" & special_remark == "HEALTH SCIENCES CAMPUS (BOSTON & GRAFTON)"
	replace new_institution = "TUFTS-NEW ENGLAND MEDICAL CENTER" if institution == "TUFTS UNIVERSITY" & location == "ON CAMPUS" & applicable == "INSTRUCTION" & special_remark == "HEALTH SCIENCES (BOSTON AND GRAFTON)"
	replace new_institution = "TUFTS-NEW ENGLAND MEDICAL CENTER" if institution == "TUFTS UNIVERSITY" & location == "ON CAMPUS" & applicable == "INSTRUCTION" & special_remark == "HEALTH SCIENCES CAMPUS (BOSTON & GRAFTON)"
	replace new_institution = "TUFTS-NEW ENGLAND MEDICAL CENTER" if institution == "TUFTS UNIVERSITY" & location == "ON CAMPUS" & applicable == "OTHER SPONSORED PROGRAMS" & special_remark == "HEALTH SCIENCES (BOSTON AND GRAFTON)"
	replace new_institution = "TUFTS-NEW ENGLAND MEDICAL CENTER" if institution == "TUFTS UNIVERSITY" & location == "ON CAMPUS" & applicable == "OTHER SPONSORED PROGRAMS" & special_remark == "HEALTH SCIENCES CAMPUS (BOSTON & GRAFTON)"
	replace new_institution = "TUFTS-NEW ENGLAND MEDICAL CENTER" if institution == "TUFTS UNIVERSITY" & location == "ON CAMPUS" & applicable == "RESEARCH" & special_remark == "HEALTH SCIENCES (BOSTON AND GRAFTON)"
	replace new_institution = "TUFTS-NEW ENGLAND MEDICAL CENTER" if institution == "TUFTS UNIVERSITY" & location == "ON CAMPUS" & applicable == "RESEARCH" & special_remark == "HEALTH SCIENCES CAMPUS (BOSTON & GRAFTON)"
	replace new_institution = "TUFTS UNIVERSITY - MEDFORD" if institution == "TUFTS UNIVERSITY" & location == "OFF CAMPUS" & applicable == "OTHER SPONSORED PROGRAMS" & special_remark == "MEDFORD/SOMERVILLE CAMPUS"
	replace new_institution = "TUFTS UNIVERSITY - MEDFORD" if institution == "TUFTS UNIVERSITY" & location == "OFF CAMPUS" & applicable == "RESEARCH" & special_remark == "MEDFORD/SOMERVILLE CAMPUS"
	replace new_institution = "TUFTS UNIVERSITY - MEDFORD" if institution == "TUFTS UNIVERSITY" & location == "ON CAMPUS" & applicable == "INSTRUCTION" & special_remark == "MEDFORD/SOMERVILLE CAMPUS"
	replace new_institution = "TUFTS UNIVERSITY - MEDFORD" if institution == "TUFTS UNIVERSITY" & location == "ON CAMPUS" & applicable == "OTHER SPONSORED PROGRAMS" & special_remark == "MEDFORD/SOMERVILLE CAMPUS"
	replace new_institution = "TUFTS UNIVERSITY - MEDFORD" if institution == "TUFTS UNIVERSITY" & location == "ON CAMPUS" & applicable == "RESEARCH" & special_remark == "MEDFORD/SOMERVILLE CAMPUS"
	replace new_institution = "UNIVERSITY HOSPITALS OF CLEVELAND" if institution == "CASE WESTERN RESERVE UNIVERSITY" & location == "UNIVERSITY HOSPITAL" & applicable == "ORGANIZED RESEARCH" & special_remark == ""
	replace new_institution = "UNIVERSITY HOSPITALS OF CLEVELAND" if institution == "CASE WESTERN RESERVE UNIVERSITY" & location == "UNIVERSITY HOSPITAL" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "UNIVERSITY OF ALASKA AT ANCHORAGE" if institution == "UNIVERSITY OF ALASKA" & location == "ANCHORAGE CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == ""
	replace new_institution = "UNIVERSITY OF ALASKA AT ANCHORAGE" if institution == "UNIVERSITY OF ALASKA" & location == "ANCHORAGE CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "AMERICAN RUSSIAN CENTER"
	replace new_institution = "UNIVERSITY OF ALASKA AT ANCHORAGE" if institution == "UNIVERSITY OF ALASKA" & location == "ANCHORAGE CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "OTHER SPONSORED ACTIVITIES"
	replace new_institution = "UNIVERSITY OF ALASKA AT ANCHORAGE" if institution == "UNIVERSITY OF ALASKA" & location == "ANCHORAGE CAMPUS" & applicable == "OTHER SPONSORED ACTIVITIES" & special_remark == ""
	replace new_institution = "UNIVERSITY OF ALASKA AT FAIRBANKS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "-" & special_remark == "ARSC"
	replace new_institution = "UNIVERSITY OF ALASKA AT FAIRBANKS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "-" & special_remark == "POKER FLAT"
	replace new_institution = "UNIVERSITY OF ALASKA AT FAIRBANKS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == ""
	replace new_institution = "UNIVERSITY OF ALASKA AT FAIRBANKS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "ARCTIC REGION SUPERCOMPUTING CENTER"
	replace new_institution = "UNIVERSITY OF ALASKA AT FAIRBANKS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "ARSC"
	replace new_institution = "UNIVERSITY OF ALASKA AT FAIRBANKS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "ON CAMPUS"
	replace new_institution = "UNIVERSITY OF ALASKA AT FAIRBANKS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "OTHER SPONSORED ACTIVITIES"
	replace new_institution = "UNIVERSITY OF ALASKA AT FAIRBANKS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "POKER FLAT"
	replace new_institution = "UNIVERSITY OF ALASKA AT FAIRBANKS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "SHIP OPERATIONS"
	replace new_institution = "UNIVERSITY OF ALASKA AT FAIRBANKS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "OTHER SPONSORED ACTIVITIES" & special_remark == ""
	replace new_institution = "UNIVERSITY OF ALASKA SOUTHEAST" if institution == "UNIVERSITY OF ALASKA" & location == "SOUTHEAST CAMPUS" & applicable == "SPONSORED RESEARCH & OTHER SPONSORED ACTIVITIES" & special_remark == ""
	replace new_institution = "UNIVERSITY OF KENTUCKY MEDICAL CENTER" if institution == "UNIVERSITY OF KENTUCKY" & city == "LEXINGTON" & location == "MEDICAL CENTER" & applicable == "ORGANIZED RESEARCH"
	replace new_institution = "UNIVERSITY OF KENTUCKY MEDICAL CENTER" if institution == "UNIVERSITY OF KENTUCKY" & city == "LEXINGTON" & location == "MEDICAL CENTER" & applicable == "RESEARCH"
	replace new_institution = "UNIVERSITY OF MIAMI SCHOOL OF MEDICINE" if institution == "UNIVERSITY OF MIAMI" & location == "OFF CAMPUS" & applicable == "INSTRUCTION - MEDICINE" & special_remark == ""
	replace new_institution = "UNIVERSITY OF MIAMI SCHOOL OF MEDICINE" if institution == "UNIVERSITY OF MIAMI" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "UNIVERSITY OF MIAMI SCHOOL OF MEDICINE"
	replace new_institution = "UNIVERSITY OF MIAMI SCHOOL OF MEDICINE" if institution == "UNIVERSITY OF MIAMI" & location == "OFF CAMPUS" & applicable == "RESEARCH - MEDICINE" & special_remark == ""
	replace new_institution = "UNIVERSITY OF MIAMI SCHOOL OF MEDICINE" if institution == "UNIVERSITY OF MIAMI" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "MED"
	replace new_institution = "UNIVERSITY OF MIAMI SCHOOL OF MEDICINE" if institution == "UNIVERSITY OF MIAMI" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "UNIVERSITY OF MIAMI SCHOOL OF MEDICINE"
	replace new_institution = "UNIVERSITY OF MIAMI SCHOOL OF MEDICINE" if institution == "UNIVERSITY OF MIAMI" & location == "ON CAMPUS" & applicable == "RESEARCH - MEDICINE" & special_remark == ""
	replace new_institution = "UNIVERSITY OF PITTSBURGH MEDICAL CENTER" if institution == "UNIVERSITY OF PITTSBURGH" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "MEDICAL CENTER"
	replace new_institution = "UNIVERSITY OF PITTSBURGH MEDICAL CENTER" if institution == "UNIVERSITY OF PITTSBURGH" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "MEDICAL CENTER"
	replace new_institution = "UNIVERSITY OF PUERTO RICO AT CAYEY" if institution == "UNIVERSITY OF PUERTO RICO MEDICAL SCIENCES" & city == "SAN JUAN" & location == "ON CAMPUS" & applicable == "CAYEY"
	replace new_institution = "UNIVERSITY OF PUERTO RICO AT CAYEY" if institution == "UNIVERSITY OF PUERTO RICO" & location == "ON CAMPUS" & applicable == "CAYEY" & special_remark == ""
	replace new_institution = "UNIVERSITY OF PUERTO RICO AT HUMACAO" if institution == "UNIVERSITY OF PUERTO RICO MEDICAL SCIENCES" & city == "SAN JUAN" & location == "ON CAMPUS" & applicable == "HUMACAO"
	replace new_institution = "UNIVERSITY OF PUERTO RICO AT HUMACAO" if institution == "UNIVERSITY OF PUERTO RICO" & location == "ON CAMPUS" & applicable == "HUMACAO" & special_remark == ""
	replace new_institution = "UNIVERSITY OF PUERTO RICO AT MAYAGUEZ" if institution == "UNIVERSITY OF PUERTO RICO MEDICAL SCIENCES" & city == "SAN JUAN" & location == "ON CAMPUS" & applicable == "MAYAGUEZ"
	replace new_institution = "UNIVERSITY OF PUERTO RICO AT RIO PIEDRAS" if institution == "UNIVERSITY OF PUERTO RICO MEDICAL SCIENCES" & city == "SAN JUAN" & location == "ON CAMPUS" & applicable == "RIO PIEDRAS"
	replace new_institution = "UNIVERSITY OF PUERTO RICO MAYAGUEZ" if institution == "UNIVERSITY OF PUERTO RICO" & location == "ON CAMPUS" & applicable == "MAYAGUEZ" & special_remark == ""
	replace new_institution = "UNIVERSITY OF PUERTO RICO MEDICAL SCIENCES" if institution == "UNIVERSITY OF PUERTO RICO" & location == "ON CAMPUS" & applicable == "MEDICAL SCIENCE" & special_remark == ""
	replace new_institution = "UNIVERSITY OF PUERTO RICO RIO PIEDRAS" if institution == "UNIVERSITY OF PUERTO RICO" & location == "ON CAMPUS" & applicable == "RIO PIEDRAS" & special_remark == ""
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT AIKEN" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "AIKEN" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT AIKEN" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "AIKEN"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT AIKEN" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "AIKEN"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT AIKEN" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "AIKEN"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT AIKEN" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "AIKEN"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT BEAUFORT" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "BEAUFORT" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT BEAUFORT" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "BEAUFORT"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT BEAUFORT" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "BEAUFORT"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT BEAUFORT" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "BEAUFORT"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT BEAUFORT" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "BEAUFORT"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT COASTAL" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "COASTAL" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT COLUMBIA" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "INSTRUCTION" & special_remark == ""
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT COLUMBIA" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == ""
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT COLUMBIA" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "COLUMBIA CAMPUS, EXCLUDING THE SCHOOL OF MEDICINE"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT COLUMBIA" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "COLUMBIA CAMPUS, SCHOOL OF MEDICINE"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT COLUMBIA" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "OTHER SPONSORED ACTIVITIES" & special_remark == ""
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT COLUMBIA" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT COLUMBIA" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "INSTRUCTION" & special_remark == ""
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT COLUMBIA" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == ""
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT COLUMBIA" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "COLUMBIA CAMPUS, EXCLUDING THE SCHOOL OF MEDICINE"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT COLUMBIA" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "COLUMBIA CAMPUS, SCHOOL OF MEDICINE"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT COLUMBIA" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "OTHER SPONSORED ACTIVITIES" & special_remark == ""
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT COLUMBIA" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "RESEARCH" & special_remark == ""
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT LANCASTER" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "LANCASTER" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT LANCASTER" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "LANCASTER"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT LANCASTER" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "LANCASTER"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT LANCASTER" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "LANCASTER"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT LANCASTER" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "LANCASTER"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT SALKEHATCHIE" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "SALKAHATCHIE"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT SALKEHATCHIE" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "SALKAHATCHIE"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT SALKEHATCHIE" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "SALKAHATCHIE"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT SALKEHATCHIE" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "SALKAHATCHIE"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT SALKEHATCHIE" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "SALKHATCHIE" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT SPARTANBURG" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "SPARTANBURG"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT SPARTANBURG" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "SPARTANBURG"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT SPARTANBURG" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "SPARTANBURG"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT SPARTANBURG" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "SPARTANBURG"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT SPARTANBURG" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "SPARTANBURG" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT SUMTER" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "SUMTER"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT SUMTER" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "SUMTER"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT SUMTER" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "SUMTER"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT SUMTER" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "SUMTER"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT SUMTER" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "SUMTER" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT UNION" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "UNION"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT UNION" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "OFF CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "UNION"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT UNION" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ALL PROGRAMS" & special_remark == "UNION"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT UNION" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "ON CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "UNION"
	replace new_institution = "UNIVERSITY OF SOUTH CAROLINA AT UNION" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "UNION" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "UNIVERSITY OF TENNESSEE SPACE INSTITUTE" if institution == "UNIVERSITY OF TENNESSEE AT KNOXVILLE" & location == "OFF CAMPUS" & applicable == "INSTRUCTION" & special_remark == "SPACE INSTITUTE"
	replace new_institution = "UNIVERSITY OF TENNESSEE SPACE INSTITUTE" if institution == "UNIVERSITY OF TENNESSEE AT KNOXVILLE" & location == "OFF CAMPUS" & applicable == "RESEARCH" & special_remark == "SPACE INSTITUTE"
	replace new_institution = "UNIVERSITY OF TENNESSEE SPACE INSTITUTE" if institution == "UNIVERSITY OF TENNESSEE AT KNOXVILLE" & location == "ON CAMPUS" & applicable == "INSTRUCTION" & special_remark == "SPACE INSTITUTE"
	replace new_institution = "UNIVERSITY OF TENNESSEE SPACE INSTITUTE" if institution == "UNIVERSITY OF TENNESSEE AT KNOXVILLE" & location == "ON CAMPUS" & applicable == "RESEARCH" & special_remark == "SPACE INSTITUTE & MHD FACILITY"
	replace new_institution = "UNIVERSITY OF TENNESSEE SPACE INSTITUTE" if institution == "UNIVERSITY OF TENNESSEE AT KNOXVILLE" & location == "ON CAMPUS" & applicable == "RESEARCH" & special_remark == "SPACE INSTITUTE"
	replace new_institution = "WADSWORTH CENTER FOR LABORATORIES AND RESEARCH" if institution == "HEALTH RESEARCH, INC." & location == "ALBANY INSTITUTIONAL" & applicable == "RESEARCH" & special_remark == "THE INSTITUTIONAL RATE IS APPLICABLE TO THE FOLLOWING: HELEN HAYES HOSPITAL AND THE WADSWORTH CENTER FOR LABORATORIES AND RESEARCH."
	replace new_institution = "WESTFIELD STATE UNIVERSITY" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "WESTFIELD" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "WORCESTER STATE UNIVERSITY" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "WORCESTER" & applicable == "ALL PROGRAMS" & special_remark == ""
	replace new_institution = "YERKES REGIONAL PRIMATE RESEARCH CENTER" if institution == "EMORY UNIVERSITY" & location == "OFF CAMPUS" & applicable == "YERKES NON P-51" & special_remark == ""
	replace new_institution = "YERKES REGIONAL PRIMATE RESEARCH CENTER" if institution == "EMORY UNIVERSITY" & location == "ON CAMPUS" & applicable == "YERKES NON P-51" & special_remark == ""
	replace new_institution = "YERKES REGIONAL PRIMATE RESEARCH CENTER" if institution == "EMORY UNIVERSITY" & location == "ON CAMPUS" & applicable == "YERKES P-51" & special_remark == ""
	
	// ----- replace new_location with corrected location information ----- //
	replace new_location = "ATLANTA LAB" if institution == "GEORGIA INSTITITE OF TECHNOLOGY APPLIED RESEAR CORPORATION" & location == "GTRI" & applicable == "ALL ACTIVITIES"
	replace new_location = "OFF CAMPUS" if institution == "COLUMBIA UNIVERSITY" & location == "LDEO OFF CAMPUS" & applicable == "RESEARCH"
	replace new_location = "ON CAMPUS" if institution == "ANTIOCH UNIVERSITY" & location == "NEW ENGLAND CAMPUS" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "ANTIOCH UNIVERSITY" & location == "SEATTLE CAMPUS" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "ANTIOCH UNIVERSITY" & location == "SOUTHERN CALIFORNIA CAMPUS" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "ANTIOCH UNIVERSITY" & location == "YELLOW SPRINGS CAMPUS" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "COLUMBIA UNIVERSITY" & location == "LDEO ON CAMPUS" & applicable == "RESEARCH"
	replace new_location = "ON CAMPUS" if institution == "HARVARD MEDICAL SCHOOL" & location == "SCHOOL OF PUBLIC HEALTH" & applicable == "RESEARCH"
	replace new_location = "ON CAMPUS" if institution == "HARVARD UNIVERSITY SCHOOL OF PUBLIC HEALTH" & location == "MEDICAL SCHOOL AND AFFILIATED HOSPITAL" & applicable == "RESEARCH"
	replace new_location = "ON CAMPUS" if institution == "HARVARD UNIVERSITY" & location == "MEDICAL SCHOOL AND AFFILIATED HOSPITAL" & applicable == "RESEARCH"
	replace new_location = "ON CAMPUS" if institution == "HARVARD UNIVERSITY" & location == "MEDICAL SCHOOL" & applicable == "RESEARCH"
	replace new_location = "ON CAMPUS" if institution == "HARVARD UNIVERSITY" & location == "SCHOOL OF PUBLIC HEALTH" & applicable == "RESEARCH"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & location == "BERKSHIRE" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & location == "BRISTOL" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & location == "BUNKER HILL" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & location == "CAPE COD" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & location == "GREENFIELD" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & location == "HOLYOKE" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & location == "MASSACHUSETTS BAY" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & location == "MASSASOIT" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & location == "MIDDLESEX" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & location == "MT. WACHUSETT" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & location == "NORTH ESSEX" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & location == "NORTH SHORE" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & location == "QUINSIGAMOND" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & location == "ROXBURY" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS REGIONAL COMMUNITY COLLEGES" & location == "SPRINGFIELD" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "BRIDGEWATER" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "COLLEGE OF ART" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "COLLEGE OF LIBERAL ARTS" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "FITCHBURG" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "MARITIME ACADEMY" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "NORTH ADAMS" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "SALEM" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "WESTFIELD" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "MASSACHUSETTS STATE COLLEGE SYSTEM" & location == "WORCESTER" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "OREGON HEALTH AND SCIENCE UNIVERSITY" & location == "OREGON NATIONAL PRIMATE RESEARCH CENTER" & applicable == "CORE GRANT"
	replace new_location = "ON CAMPUS" if institution == "OREGON HEALTH AND SCIENCE UNIVERSITY" & location == "OREGON NATIONAL PRIMATE RESEARCH CENTER" & applicable == "RESEARCH"
	replace new_location = "ON CAMPUS" if institution == "OREGON HEALTH SCIENCES UNIVERSITY" & location == "OREGON NATIONAL PRIMATE RESEARCH CENTER" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "OREGON HEALTH SCIENCES UNIVERSITY" & location == "OREGON NATIONAL PRIMATE RESEARCH CENTER" & applicable == "CORE GRANT"
	replace new_location = "ON CAMPUS" if institution == "OREGON HEALTH SCIENCES UNIVERSITY" & location == "OREGON NATIONAL PRIMATE RESEARCH CENTER" & applicable == "RESEARCH & GENERAL CLINICAL RESEARCH CENTER"
	replace new_location = "ON CAMPUS" if institution == "OREGON HEALTH SCIENCES UNIVERSITY" & location == "OREGON NATIONAL PRIMATE RESEARCH CENTER" & applicable == "RESEARCH"
	replace new_location = "ON CAMPUS" if institution == "PENNSYLVANIA STATE UNIVERSITY" & location == "GEISINGER CENTER" & applicable == "-"
	replace new_location = "ON CAMPUS" if institution == "PENNSYLVANIA STATE UNIVERSITY" & location == "GEISINGER CENTER" & applicable == "RESEARCH"
	replace new_location = "ON CAMPUS" if institution == "PENNSYLVANIA STATE UNIVERSITY" & location == "WEIS RESEARCH CENTER" & applicable == "-"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF ALASKA" & location == "ANCHORAGE CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == ""
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF ALASKA" & location == "ANCHORAGE CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "OTHER SPONSORED ACTIVITIES"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF ALASKA" & location == "ANCHORAGE CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "AMERICAN RUSSIAN CENTER"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "-" & special_remark == "POKER FLAT"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "-" & special_remark == "ARSC"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "SHIP OPERATIONS"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "POKER FLAT"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "OTHER SPONSORED ACTIVITIES" & special_remark == ""
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "ON CAMPUS"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF ALASKA" & location == "SOUTHEAST CAMPUS" & applicable == "SPONSORED RESEARCH & OTHER SPONSORED ACTIVITIES" & special_remark == ""
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "OTHER SPONSORED ACTIVITIES"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "ARSC"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == ""
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF ALASKA" & location == "ANCHORAGE CAMPUS" & applicable == "OTHER SPONSORED ACTIVITIES" & special_remark == ""
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "ORGANIZED RESEARCH" & special_remark == "ARCTIC REGION SUPERCOMPUTING CENTER"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF CALIFORNIA AT DAVIS" & location == "CALIFORNIA NATIONAL PRIMATE RESEARCH CENTER" & applicable == "CORE GRANT"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF CALIFORNIA AT DAVIS" & location == "CALIFORNIA NATIONAL PRIMATE RESEARCH CENTER" & applicable == "RESEARCH"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF CALIFORNIA AT DAVIS" & location == "CALIFORNIA REGIONAL PRIMATE CENTER & INSTITUTE OF TOXICOLOGY AND ENVIRONMENTAL HEALTH" & applicable == "RESEARCH"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "AIKEN" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "BEAUFORT" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "COASTAL" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "LANCASTER" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "SALKHATCHIE" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "SPARTANBURG" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "SUMTER" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "UNIVERSITY OF SOUTH CAROLINA" & location == "UNION" & applicable == "ALL PROGRAMS"
	replace new_location = "ON CAMPUS" if institution == "WEST VIRGINIA UNIVERSITY" & location == "BLANCHETTE ROCKEFELLER NEUROSCIENCE INSTITUTE" & applicable == "ORGANIZED RESEARCH"
	replace new_location = "ON SITE" if institution == "ALBERT EINSTEIN HEALTHCARE NETWORK" & location == "ALBERT EINSTEIN MEDICAL CENTER" & applicable == "ORGANIZED RESEARCH"
	replace new_location = "ON SITE" if institution == "ALBERT EINSTEIN HEALTHCARE NETWORK" & location == "BELMONT BEHAVIORAL HEALTH" & applicable == "ORGANIZED RESEARCH"
	replace new_location = "ON SITE" if institution == "ALBERT EINSTEIN HEALTHCARE NETWORK" & location == "MOSS REHABILITATION HOSPITAL" & applicable == "ORGANIZED RESEARCH"
	replace new_location = "ON SITE" if institution == "BLOOD SYSTEMS, INC." & location == "BSRI - SF" & applicable == "RESEARCH"
	replace new_location = "ON SITE" if institution == "CASE WESTERN RESERVE UNIVERSITY" & location == "CMG HOSPITAL" & applicable == "RESEARCH"
	replace new_location = "ON SITE" if institution == "CASE WESTERN RESERVE UNIVERSITY" & location == "METROHEALTH MEDICAL CENTER" & applicable == "ORGANIZED RESEARCH"
	replace new_location = "ON SITE" if institution == "CASE WESTERN RESERVE UNIVERSITY" & location == "UNIVERSITY HOSPITAL" & applicable == "ORGANIZED RESEARCH"
	replace new_location = "ON SITE" if institution == "CASE WESTERN RESERVE UNIVERSITY" & location == "UNIVERSITY HOSPITAL" & applicable == "RESEARCH"
	replace new_location = "ON SITE" if institution == "CHILDREN'S HOSPITAL AND REGIONAL MEDICAL CENTER" & location == "WESTLAKE" & applicable == "BENCH RESEARCH"
	replace new_location = "ON SITE" if institution == "HEALTH RESEARCH, INC." & location == "ALBANY INSTITUTIONAL" & applicable == "RESEARCH"
	replace new_location = "ON SITE" if institution == "HEALTH RESEARCH, INC." & location == "ROSWELL PARK MEMORIAL INSTITUTE" & applicable == "RESEARCH"
	replace new_location = "ON SITE" if institution == "INDIANA UNIVERSITY" & location == "HOSPITAL" & applicable == "GENERAL CLINICAL RESEARCH CENTER"
	replace new_location = "ON SITE" if institution == "INDIANA UNIVERSITY" & location == "INDIANA UNIVERSITY HOSPITAL" & applicable == "GENERAL CLINICAL RESEARCH CENTER"
	replace new_location = "ON SITE" if institution == "MEDICAL COLLEGE OF WISCONSIN" & location == "FROEDTERT MEMORIAL LUTHERAN HOSPITAL" & applicable == "ORGANIZED RESEARCH"
	replace new_location = "ON SITE" if institution == "MEDICAL COLLEGE OF WISCONSIN" & location == "FROEDTERT MEMORIAL LUTHERAN HOSPITAL" & applicable == "RESEARCH"
	replace new_location = "ON SITE" if institution == "MEDICAL COLLEGE OF WISCONSIN" & location == "MILWAUKEE COUNTY MEDICAL COMPLEX HOSPITAL" & applicable == "RESEARCH"
	replace new_location = "ON SITE" if institution == "MEDSTAR RESEARCH INSTITUTE" & location == "HARBOR HOSPITAL" & applicable == "NIA"
	replace new_location = "ON SITE" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC." & location == "INSTITUTE FOR BASIC RESEARCH" & applicable == "-"
	replace new_location = "ON SITE" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC." & location == "INSTITUTE FOR BASIC RESEARCH" & applicable == "RESEARCH"
	replace new_location = "ON SITE" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC." & location == "KLINE RESEARCH CENTER" & applicable == "-"
	replace new_location = "ON SITE" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC." & location == "KLINE RESEARCH CENTER" & applicable == "RESEARCH"
	replace new_location = "ON SITE" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC." & location == "NEW YORK PSYCHIATRIC INSTITUTE" & applicable == "-"
	replace new_location = "ON SITE" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC." & location == "NEW YORK PSYCHIATRIC INSTITUTE" & applicable == "RESEARCH"
	replace new_location = "ON SITE" if institution == "SCRIPPS RESEARCH INSTITUTE" & location == "CALIFORNIA" & applicable == "RESEARCH"
	replace new_location = "ON SITE" if institution == "SCRIPPS RESEARCH INSTITUTE" & location == "FLORIDA" & applicable == "RESEARCH"
	replace new_location = "ON SITE" if institution == "UNIVERSITY OF KENTUCKY" & location == "MEDICAL CENTER" & applicable == "ORGANIZED RESEARCH"
	replace new_location = "ON SITE" if institution == "UNIVERSITY OF KENTUCKY" & location == "MEDICAL CENTER" & applicable == "RESEARCH"
	replace new_location = "ON SITE" if institution == "UNIVERSITY OF WASHINGTON" & location == "HARBORVIEW MEDICAL CENTER" & applicable == "-"
	replace new_location = "ON SITE" if institution == "YALE UNIVERSITY" & location == "CONNECTICUT MENTAL HEALTH CENTER" & applicable == "ORGANIZED RESEARCH"
	
	// ----- replace new_applicable with corrected applicable information----- //
	replace new_applicable = "ALL PROGRAMS" if institution == "LOUISIANA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "AGRICULTURE EXPERIMENT STATION"
	replace new_applicable = "ALL PROGRAMS" if institution == "LOUISIANA STATE UNIVERSITY" & location == "OFF CAMPUS" & applicable == "AGRICULTURE RESEARCH CENTER"
	replace new_applicable = "ALL PROGRAMS" if institution == "LOUISIANA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "AGRICULTURE EXPERIMENT STATION"
	replace new_applicable = "ALL PROGRAMS" if institution == "LOUISIANA STATE UNIVERSITY" & location == "ON CAMPUS" & applicable == "AGRICULTURE RESEARCH CENTER"
	replace new_applicable = "ALL PROGRAMS" if institution == "LUTHERAN MEDICAL CENTER" & location == "ALL LOCATIONS" & applicable == "SUNSET PARK FAMILY HEALTH CENTER"
	replace new_applicable = "ALL PROGRAMS" if institution == "PENNSYLVANIA STATE UNIVERSITY" & location == "GEISINGER CENTER" & applicable == "-"
	replace new_applicable = "ALL PROGRAMS" if institution == "PENNSYLVANIA STATE UNIVERSITY" & location == "WEIS RESEARCH CENTER" & applicable == "-"
	replace new_applicable = "ALL PROGRAMS" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC." & location == "INSTITUTE FOR BASIC RESEARCH" & applicable == "-"
	replace new_applicable = "ALL PROGRAMS" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC." & location == "KLINE RESEARCH CENTER" & applicable == "-"
	replace new_applicable = "ALL PROGRAMS" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC." & location == "NEW YORK PSYCHIATRIC INSTITUTE" & applicable == "-"
	replace new_applicable = "ALL PROGRAMS" if institution == "UNIVERSITY OF ALASKA" & location == "FAIRBANKS CAMPUS" & applicable == "-"
	replace new_applicable = "ALL PROGRAMS" if institution == "UNIVERSITY OF FLORIDA" & location == "OFF CAMPUS" & applicable == "AGRICULTURE RESEARCH AND EDUCATION CENTER & FLORIDA MEDICAL ENTOMOLOGY LABORATORY"
	replace new_applicable = "ALL PROGRAMS" if institution == "UNIVERSITY OF FLORIDA" & location == "ON CAMPUS" & applicable == "AGRICULTURE RESEARCH AND EDUCATION CENTER & FLORIDA MEDICAL ENTOMOLOGY LABORATORY"
	replace new_applicable = "ALL PROGRAMS" if institution == "UNIVERSITY OF PUERTO RICO MEDICAL SCIENCES" & location == "ON CAMPUS" & applicable == "CAYEY"
	replace new_applicable = "ALL PROGRAMS" if institution == "UNIVERSITY OF PUERTO RICO MEDICAL SCIENCES" & location == "ON CAMPUS" & applicable == "HUMACAO"
	replace new_applicable = "ALL PROGRAMS" if institution == "UNIVERSITY OF PUERTO RICO MEDICAL SCIENCES" & location == "ON CAMPUS" & applicable == "MAYAGUEZ"
	replace new_applicable = "ALL PROGRAMS" if institution == "UNIVERSITY OF PUERTO RICO MEDICAL SCIENCES" & location == "ON CAMPUS" & applicable == "RIO PIEDRAS"
	replace new_applicable = "ALL PROGRAMS" if institution == "UNIVERSITY OF PUERTO RICO" & location == "ON CAMPUS" & applicable == "CAYEY"
	replace new_applicable = "ALL PROGRAMS" if institution == "UNIVERSITY OF PUERTO RICO" & location == "ON CAMPUS" & applicable == "HUMACAO"
	replace new_applicable = "ALL PROGRAMS" if institution == "UNIVERSITY OF PUERTO RICO" & location == "ON CAMPUS" & applicable == "MAYAGUEZ"
	replace new_applicable = "ALL PROGRAMS" if institution == "UNIVERSITY OF PUERTO RICO" & location == "ON CAMPUS" & applicable == "MEDICAL SCIENCE"
	replace new_applicable = "ALL PROGRAMS" if institution == "UNIVERSITY OF PUERTO RICO" & location == "ON CAMPUS" & applicable == "RIO PIEDRAS"
	replace new_applicable = "ALL PROGRAMS" if institution == "UNIVERSITY OF WASHINGTON" & location == "HARBORVIEW MEDICAL CENTER" & applicable == "-"
	replace new_applicable = "NON-P51 PROGRAMS" if institution == "EMORY UNIVERSITY" & location == "OFF CAMPUS" & applicable == "YERKES NON P-51"
	replace new_applicable = "NON-P51 PROGRAMS" if institution == "EMORY UNIVERSITY" & location == "ON CAMPUS" & applicable == "YERKES NON P-51"
	replace new_applicable = "P51-PROGRAMS" if institution == "EMORY UNIVERSITY" & location == "ON CAMPUS" & applicable == "YERKES P-51"
	replace new_applicable = "RESEARCH" if institution == "NEW YORK UNIVERSITY MEDICAL CENTER" & location == "ALL LOCATIONS" & applicable == "RESEARCH & REGIONAL MEDICAL PROGRAM"
	replace new_applicable = "RESEARCH" if institution == "OREGON HEALTH SCIENCES UNIVERSITY" & location == "OREGON NATIONAL PRIMATE RESEARCH CENTER" & applicable == "RESEARCH & GENERAL CLINICAL RESEARCH CENTER"
	replace new_applicable = "SPONSORED RESEARCH" if institution == "UNIVERSITY OF ALASKA" & location == "SOUTHEAST CAMPUS" & applicable == "SPONSORED RESEARCH & OTHER SPONSORED ACTIVITIES"
	
	// ----- replace new_special_remark with corrected special_remark information----- //
	replace new_special_remark = "DOD CONTRACTS AFTER 30 NOVEMBER 1993" if strpos(special_remark, "DOD CONTRACTS AFTER")
	replace new_special_remark = "DOD CONTRACTS BEFORE 30 NOVEMBER 1993 AND NON-DOD INSTRUMENTS" if strpos(special_remark, "DOD CONTRACTS BEFORE")
	replace new_special_remark = "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC. AND NYS DEPT. OF MENTAL HYGIENE" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC."

	// ----- the following for loop makes the substitutions above ----- //
	foreach variable in institution location applicable special_remark {
		replace new_`variable' = `variable' if missing(new_`variable')
		drop `variable'
		rename new_`variable' `variable'
	}

/* ------------------------------- Begin Note ------------------------------- // 

	Operation 02: Further standardization of institution names. 
	
	We note, only those institutions where at least one observation was changed
	appears in the code below. For example, the data include both "THE GEORGE 
	WASHINGTON UNIVERSITY" and "GEORGE WASHINGTON UNIVERSITY". We chose to use 
	"GEORGE WASHINGTON UNIVERSITY" so users will find:
	
	. replace institution = "GEORGE WASHINGTON UNIVERSITY" if institution == "THE GEORGE WASHINGTON UNIVERSITY"
	
	but will not find: 
	
	. replace institution = "GEORGE WASHINGTON UNIVERSITY" if institution == "GEORGE WASHINGTON UNIVERSITY"
	
	because the latter does not actually result in any changes. 
	
// -------------------------------- End Note -------------------------------- */


// ------- standardize institutions ------- //

	// ----- keep institution names for final concordance ----- //
	gen post_subinstitution = institution
	
	// ----- simple changes based solely on institution name ----- //
	replace institution = "AARON DIAMOND AIDS RESEARCH CENTER" if institution == "THE AARON DIAMOND AIDS RESEARCH CENTER"
	replace institution = "AIDS RESEARCH CONSORTIUM OF ATLANTA INC" if institution == "AIDS RESEARCH CONSORTIUM OF ATLANTA"
	replace institution = "ALBANY MEDICAL CENTER" if institution == "ALBANY MEDICAL COLLEGE OF UNION UNIVERSITY"
	replace institution = "ALBANY RESEARCH INSTITUTE INC" if institution == "ALBANY RESEARCH INSTITUTE, INC."
	replace institution = "ALBANY STATE UNIVERSITY" if institution == "ALBANY STATE COLLEGE"
	replace institution = "ALBERT EINSTEIN MEDICAL CENTER" if institution == "ALBERT EINSTEIN HEALTHCARE NETWORK"
	replace institution = "ALLEGHENY UNIVERSITY OF HEALTH SCIENCES (MCP HAHNEMANN UNIVERSITY)" if institution == "ALLEGHENY UNIVERSITY OF THE HEALTH SCIENCES"
	replace institution = "ALLEGHENY UNIVERSITY OF HEALTH SCIENCES (MCP HAHNEMANN UNIVERSITY)" if institution == "HAHNEMANN UNIVERSITY"
	replace institution = "ALLEGHENY UNIVERSITY OF HEALTH SCIENCES (MCP HAHNEMANN UNIVERSITY)" if institution == "PHILADELPHIA HEALTH AND EDUCATION CORPORATION"
	replace institution = "ALLEGHENY UNIVERSITY OF HEALTH SCIENCES (MCP HAHNEMANN UNIVERSITY)" if institution == "MEDICAL COLLEGE OF PENNSYLVANIA"
	replace institution = "ALLIANT INTERNATIONAL UNIVERSITY AT LOS ANGELES" if institution == "ALLIANT INTERNATIONAL UNIVERSITY"
	replace institution = "AMERICAN CANCER SOCIETY INC" if institution == "AMERICAN CANCER SOCIETY"
	replace institution = "AMERICAN COLLEGE OF PHYSICANS" if institution == "AMERICAN COLLEGE OF PHYSICIANS"
	replace institution = "AMERICAN NATIONAL RED CROSS" if institution == "AMERICAN RED CROSS, NATIONAL CAPITAL AREA CHAPTER"
	replace institution = "AMERICAN NATIONAL RED CROSS" if institution == "AMERICAN RED CROSS - NATIONAL HEADQUARTERS"
	replace institution = "AMERICAN NATIONAL RED CROSS OF SOUTHEAST MICHIGAN" if institution == "AMERICAN RED CROSS"
	replace institution = "AMERICAN UNIVERSITY" if institution == "THE AMERICAN UNIVERSITY"
	replace institution = "AMHERST H WILDER FOUNDATION" if institution == "AMHERST H. WILDER FOUNDATION"
	replace institution = "ARKANSAS CHILDRENS HOSPITAL RESEARCH INSTITUTE" if institution == "ARKANSAS CHILDREN'S HOSPITAL RESEARCH CENTER"
	replace institution = "AROOSTOOK MEDICAL CENTER" if institution == "THE AROOSTOOK MEDICAL CENTER"
	replace institution = "AUBURN UNIVERSITY AT AUBURN" if institution == "AUBURN UNIVERSITY"
	replace institution = "BALDWIN-WALLACE COLLEGE" if institution == "BALDWIN WALLACE COLLEGE"
	replace institution = "BANNER HEALTH" if institution == "BANNER HEALTH SYSTEM"
	replace institution = "BECKMAN RESEARCH INSTITUTE OF CITY OF HOPE" if institution == "BECKMAN RESEARCH INSTITUTE"
	replace institution = "BEN-GURION UNIVERSITY OF THE NEGEV" if institution == "BEN GURION UNIVERSITY OF THE NEGEV"
	replace institution = "BETH ISRAEL MEDICAL CENTER (NEW YORK)" if institution == "BETH ISRAEL MEDICAL CENTER"
	replace institution = "BLOODCENTER OF WISCONSIN INC" if institution == "BLOODCENTER OF WISCONSIN"
	replace institution = "BLOOMSBURG UNIVERSITY OF PENNSYLVANIA" if institution == "BLOOMSBURG UNIVERSITY"
	replace institution = "BON SECOURS HOSPITAL BALTIMORE INC" if institution == "BON SECOURS HOSPITAL, INC."
	replace institution = "BOYCE THOMPSON INST FOR PLANT RESEARCH" if institution == "BOYCE THOMPSON INSTITUTE FOR PLANT RESEARCH, INC."
	replace institution = "BRIDGEWATER STATE UNIVERSITY" if institution == "BRIDGEWATER STATE COLLEGE"
	replace institution = "BRIGHAM AND WOMENS HOSPITAL" if institution == "BRIGHAM AND WOMEN'S HOSPITAL"
	replace institution = "BUTLER HOSPITAL (PROVIDENCE RI)" if institution == "BUTLER HOSPITAL"
	replace institution = "CALIFORNIA STATE UNIVERSITY AT DOMINGUEZ HILLS" if institution == "CALIFORNIA STATE UNIVERSITY - DOMINGUEZ HILLS FOUNDATION"
	replace institution = "CALIFORNIA STATE UNIVERSITY AT FRESNO" if institution == "CALIFORNIA STATE UNIVERSITY - FRESNO FOUNDATION"
	replace institution = "CALIFORNIA STATE UNIVERSITY AT LOS ANGELES" if institution == "CALIFORNIA STATE UNIVERSITY AT LOS ANGELES - AUXILIARY SERVICES, INC."
	replace institution = "CALIFORNIA STATE UNIVERSITY AT SACREMENTO" if institution == "CALIFORNIA STATE UNIVERSITY - SACREMENTO FOUNDATION"
	replace institution = "CALVIN COLLEGE" if institution == "CALVIN COLLEGE AND SEMINARY"
	replace institution = "CATHOLIC UNIVERSITY OF AMERICA" if institution == "THE CATHOLIC UNIVERSITY OF AMERICA"
	replace institution = "CENTER FOR DRUG-FREE LIVING INC" if institution == "CENTER FOR DRUG FREE LIVING, INC."
	replace institution = "CENTER FOR HEALTH RESEARCH" if institution == "CENTERS FOR HEALTH RESEARCH"
	replace institution = "CENTER FOR RESEARCH TO PRACTICE INC" if institution == "CENTER FOR RESEARCH TO PRACTICE"
	replace institution = "CENTRE COLLEGE" if institution == "CENTRE COLLEGE OF KENTUCKY"
	replace institution = "CHESTNUT HEALTH SYSTEMS INC" if institution == "CHESTNUT HEALTH SYSTEMS"
	replace institution = "CHICAGO ASSOCIATION FOR RESEARCH AND EDUCATION IN SCIENCE" if institution == "CHICAGO ASSOCIATION FOR RESEARCH AND EDUCATION"
	replace institution = "CHILDREN'S HOSPITAL AND REGIONAL MEDICAL CENTER (SEATTLE)" if institution == "CHILDREN'S HOSPITAL AND REGIONAL MEDICAL CENTER"
	replace institution = "CHILDREN'S MEMORIAL HOSPITAL (CHICAGO)" if institution == "CHILDREN'S MEMORIAL HOSPITAL"
	replace institution = "CHILDREN'S MERCY HOSPITAL (KANSAS CITY, MO)" if institution == "CHILDRENS MERCY HOSPITAL"
	replace institution = "CHILDRENS HEALTHCARE OF ATLANTA INC" if institution == "CHILDREN'S HEALTHCARE OF ATLANTA, INC."
	replace institution = "CHILDRENS HOSPITAL (DENVER)" if institution == "THE CHILDREN'S HOSPITAL"
	replace institution = "CHILDRENS HOSPITAL (NEW ORLEANS)" if institution == "CHILDREN'S HOSPITAL OF NEW ORLEANS"
	replace institution = "CHILDRENS HOSPITAL MEDICAL CENTER OF AKRON" if institution == "CHILDREN'S HOSPITAL MEDICAL CENTER OF AKRON"
	replace institution = "CHILDRENS HOSPITAL OF MICHIGAN (DETROIT)" if institution == "CHILDREN'S HOSPITAL OF MICHIGAN"
	replace institution = "CHILDRENS HOSPITAL OF ORANGE COUNTY" if institution == "CHILDREN'S HOSPITAL OF ORANGE COUNTY"
	replace institution = "CHILDRENS HOSPITAL OF PHILADELPHIA" if institution == "CHILDREN'S HOSPITAL OF PHILADELPHIA"
	replace institution = "CHILDRENS HOSPITAL RESEARCH CENTER (SAN DIEGO)" if institution == "CHILDREN'S HOSPITAL RESEARCH CENTER"
	replace institution = "CHILDRENS RESEARCH TRIANGLE" if institution == "CHILDREN'S RESEARCH TRIANGLE"
	replace institution = "CHRISTIANA CARE HEALTH SERVICES INC" if institution == "CHRISTIANA CARE HEALTH SERVICES"
	replace institution = "CINCINNATI FOUNDATION FOR BIOMEDICAL RESEARCH AND EDUCATION" if institution == "CINCINNATI FOUNDATION FOR BIOMEDICAL RESEARCH"
	replace institution = "CLAFLIN UNIVERSITY" if institution == "CLAFLIN COLLEGE"
	replace institution = "CLARIAN HEALTH PARTNERS INC" if institution == "CLARIAN HEALTH PARTNERS, INC."
	replace institution = "CLARION UNIVERSITY OF PENNSYLVANIA" if institution == "CLARION UNIVERSITY"
	replace institution = "CLARK UNIVERSITY (WORCESTER MA)" if institution == "CLARK UNIVERSITY"
	replace institution = "CLINICAL DIRECTORS NETWORK INC" if institution == "CLINICAL DIRECTORS NETWORK OF REGION II, INC."
	replace institution = "COLLEGE OF CHARLESTON" if institution == "UNIVERSITY OF CHARLESTON"
	replace institution = "COLLEGE OF NEW JERSEY" if institution == "THE COLLEGE OF NEW JERSEY"
	replace institution = "COLLEGE OF SAINT CATHERINE" if institution == "COLLEGE OF ST. CATHERINE"
	replace institution = "COLLEGE OF SAINT SCHOLASTICA" if institution == "COLLEGE OF ST. SCHOLASTICA"
	replace institution = "COLLEGE OF WILLIAM AND MARY" if institution == "THE COLLEGE OF WILLIAM AND MARY"
	replace institution = "COLLEGE OF WILLIAM AND MARY" if institution == "WILLIAM AND MARY"
	replace institution = "COLORADO CANCER RESEARCH PROGRAM INC" if institution == "COLORADO CANCER RESEARCH PROGRAM, INC."
	replace institution = "COLORADO STATE UNIVERSITY AT FORT COLLINS" if institution == "COLORADO STATE UNIVERSITY"
	replace institution = "COLORADO STATE UNIVERSITY AT PUEBLO" if institution == "UNIVERSITY OF SOUTHERN COLORADO"
	replace institution = "COLUMBIA COLLEGE CHICAGO" if institution == "COLUMBIA COLLEGE"
	replace institution = "COLUMBIA UNIVERSITY IN THE CITY OF NEW YORK" if institution == "COLUMBIA UNIVERSITY"
	replace institution = "COLUMBIA UNIVERSITY TEACHERS COLLEGE" if institution == "TEACHERS COLLEGE OF COLUMBIA UNIVERSITY"
	replace institution = "COMMUNITY CENTERS OF INDIANAPOLIS INC" if institution == "COMMUNITY CENTERS OF INDIANAPOLIS, INC."
	replace institution = "COMMUNITY HEALTHLINK INC" if institution == "COMMUNITY HEALTHLINK, INC."
	replace institution = "COMMUNITY MEDICAL CENTER" if institution == "COMMUNITY MEDICAL CENTER FOUNDATION, INC."
	replace institution = "CONNECTICUT CHILDRENS MEDICAL CENTER" if institution == "CONNECTICUT CHILDREN'S MEDICAL CENTER"
	replace institution = "COOK CHILDRENS MEDICAL CENTER" if institution == "COOK CHILDREN'S MEDICAL CENTER"
	replace institution = "COOPER UNIVERSITY MEDICAL CENTER" if institution == "COOPER HOSPITAL/UNIVERSITY MEDICAL CENTER"
	replace institution = "CRITICAL PATH INSTITUTE" if institution == "THE CRITICAL PATH INSTITUTE"
	replace institution = "CTRC RESEARCH FOUNDATION" if institution == "CANCER THERAPY AND RESEARCH CENTER"
	replace institution = "DANA-FARBER CANCER INSTITUTE" if institution == "DANA FARBER CANCER INSTITUTE"
	replace institution = "DANYA INTERNATIONAL INC" if institution == "THE DANYA INSTITUTE"
	replace institution = "DE PAUL UNIVERSITY" if institution == "DEPAUL UNIVERSITY"
	replace institution = "DE PAUW UNIVERSITY" if institution == "DEPAUW UNIVERSITY"
	replace institution = "DONALD GUTHRIE FOUNDATION FOR MEDICAL RESEARCH" if institution == "DONALD GUTHRIE FOUNDATION FOR MEDICAL RESEARCH,INC"
	replace institution = "DULUTH CLINIC LTD" if institution == "DULUTH CLINIC, INC."
	replace institution = "DYOUVILLE COLLEGE" if institution == "D'YOUVILLE COLLEGE"
	replace institution = "EASTERN VIRGINIA MEDICAL SCHOOL" if institution == "MEDICAL COLLEGE OF HAMPTON ROADS"
	replace institution = "EDINBORO UNIVERSITY OF PENNSYLVANIA" if institution == "EDINBORO UNIVERSITY"
	replace institution = "EDUCATION DEVELOPMENT CENTER INC" if institution == "EDUCATION DEVELOPMENT CENTER, INC."
	replace institution = "EMMA PENDLETON BRADLEY HOSPITAL" if institution == "BRADLEY HOSPITAL/LIFESPAN"
	replace institution = "EVANSTON HOSPITAL" if institution == "EVANSTON NORTHWESTERN HEALTHCARE"
	replace institution = "FATHER FLANAGANS BOYS HOME" if institution == "FATHER FLANAGAN'S BOYS' HOME"
	replace institution = "FORSYTH INSTITUTE" if institution == "THE FORSYTH INSTITUTE"
	replace institution = "FORT VALLEY STATE UNIVERSITY" if institution == "FORT VALLEY STATE COLLEGE"
	replace institution = "FOX CHASE CANCER CENTER" if institution == "THE FOX CHASE CANCER CENTER"
	replace institution = "FRANKLIN W OLIN COLLEGE OF ENGINEERING" if institution == "FRANKLIN W. OLIN COLLEGE OF ENGINEERING"
	replace institution = "GALLAUDET UNIVERSITY" if institution == "GALLAUDET COLLEGE"
	replace institution = "GEISINGER MEDICAL CENTER" if institution == "GEISINGER CLINIC"
	replace institution = "GEORGE WASHINGTON UNIVERSITY" if institution == "THE GEORGE WASHINGTON UNIVERSITY"
	replace institution = "GEORGIA HOSPITAL ASSOCIATION RESEARCH AND EDUCATION FOUNDATION" if institution == "GEORGIA HOSPITAL ASSOCIATION"
	replace institution = "GEORGIA INSTITUTE OF TECHNOLOGY" if institution == "GEORGIA INSTITUTE OF TECHNOLOGY GEORGIA"
	replace institution = "GEORGIA INSTITUTE OF TECHNOLOGY APPLIED RESEARCH CORPORATION" if institution == "GEORGIA INSTITUE OF TECHNOLOGY GEROGIA TECH APPLIED RESEARCH CORPORATION"
	replace institution = "GEORGIA INSTITUTE OF TECHNOLOGY APPLIED RESEARCH CORPORATION" if institution == "GEORGIA TECH APPLIED RESEARCH CORPORATION"
	replace institution = "GEORGIA INSTITUTE OF TECHNOLOGY APPLIED RESEARCH CORPORATION" if institution == "GEORGIA INSTITUTE OF TECHNOLOGY RESEARCH CORPORATION"
	replace institution = "GEORGIA INSTITUTE OF TECHNOLOGY APPLIED RESEARCH CORPORATION" if institution == "GEROGIA INSTITUTE OF TECHNOLOGY GEORGIA TECH APPLIED RESEARCH CORPORATION"
	replace institution = "GEORGIA INSTITUTE OF TECHNOLOGY APPLIED RESEARCH CORPORATION" if institution == "GEORGIA INSTITUTE OF TECHNOLOGY GEORGIA TECH APPLIED RESEARCH CORPORATION"
	replace institution = "GEORGIA INSTITUTE OF TECHNOLOGY APPLIED RESEARCH CORPORATION" if institution == "GEORGIA INSTITITE OF TECHNOLOGY APPLIED RESEAR CORPORATION"
	replace institution = "GEORGIA SOUTHWESTERN STATE UNIVERSITY" if institution == "GEORGIA SOUTHWESTERN COLLEGE"
	replace institution = "GEORGIA STATE UNIVERSITY" if institution == "GEORGIA STATE UNIVERSITY AND GEORGIA STATE UNIVERSITY RESEARCH FOUNDATION"
	replace institution = "GOOD SAMARITAN HOSPITAL (LOS ANGELES, CA)" if institution == "GOOD SAMARITAN HOSPITAL"
	replace institution = "GREENWOOD GENETIC CENTER" if institution == "GREENWOOD GENETIC CENTER, INC."
	replace institution = "GROUP HEALTH COOPERATIVE OF PUGET SOUND" if institution == "GROUP HEALTH COOPERATIVE"
	replace institution = "HARDIN-SIMMONS UNIVERSITY" if institution == "HARDIN SIMMONS UNIVERSITY"
	replace institution = "HARVARD PILGRIM HEALTH CARE INC" if institution == "HARVARD PILGRIM HEALTH CARE, INC."
	replace institution = "HARVARD UNIVERSITY SCHOOL OF PUBLIC HEALTH" if institution == "HARVARD SCHOOL OF PUBLIC HEALTH"
	replace institution = "HASTINGS CENTER INC" if institution == "THE HASTINGS CENTER"
	replace institution = "HAVERFORD COLLEGE" if institution == "THE CORPORATION OF HAVERFORD COLLEGE"
	replace institution = "HEALTH RESEARCH ASSOCIATION INC" if institution == "HEALTH RESEARCH ASSOCIATION"
	replace institution = "HEALTH RESEARCH INC" if institution == "HEALTH RESEARCH, INC."
	replace institution = "HEALTHONE ALLIANCE" if institution == "HEALTHONE"
	replace institution = "HEIDELBERG UNIVERSITY" if institution == "HEIDELBERG COLLEGE"
	replace institution = "HEIDELBERG UNIVERSITY" if institution == "HEILDELBERG COLLEGE"
	replace institution = "HENRY FORD HEALTH SYSTEM" if institution == "HENRY FORD HEALTH SYSTEM IDC"
	replace institution = "HOUSTON METHODIST HOSPITAL" if institution == "METHODIST HOSPITAL"
	replace institution = "HUNTINGTON MEDICAL RESEARCH INSTITUTES" if institution == "HUNTINGTON MEDICAL RESEARCH INSTITUTE"
	replace institution = "INDIANA STATE UNIVERSITY" if institution == "INDIANA STATE UNIVERSITY/TERRE HAUTE"
	replace institution = "INDIANA UNIVERSITY OF PENNSYLVANIA" if institution == "INDIANA UNIVERSITY OF PENNSYLVANIA RESEARCH INSTITUTE"
	replace institution = "INOVA HEALTH SYSTEM FOUNDATION" if institution == "INOVA HEALTH SYSTEM"
	replace institution = "INSTITUTE FOR BASIC RESEARCH IN DEVELOPMENTAL DISABILITIES" if institution == "INSTITUTE FOR BASIC RESEARCH"
	replace institution = "INSTITUTE FOR CANCER PREVENTION" if institution == "INSTITUTION FOR CANCER PREVENTION"
	replace institution = "INSTITUTE FOR CLINICAL RESEARCH INC" if institution == "INSTITUTE FOR CLINICAL RESEARCH, INC."
	replace institution = "INSTITUTE FOR COMMUNITY RESEARCH" if institution == "THE INSTITUTE FOR COMMUNITY RESEARCH, INC."
	replace institution = "INSTITUTE FOR HEALTHY COMMUNITIES" if institution == "THE INSTITUTE FOR HEALTHY COMMUNITIES"
	replace institution = "INSTITUTE FOR NEURODEGENERATIVE DISORDERS INC" if institution == "INSTITUTE FOR NEURODEGENERATIVE DISORDERS, INC."
	replace institution = "INSTITUTE FOR THE ADVANCED STUDY OF BLACK FAMILY LIFE AND CULTURE" if institution == "INSTITUTE FOR THE ADVANCED STUDY OF BLACK FAMILY LIFE AND CULTURE, INC."
	replace institution = "INSTITUTES FOR BEHAVIOR RESOURCES INC" if institution == "INSTITUTES FOR BEHAVIOR RESOURCES, INC."
	replace institution = "INTER AMERICAN UNIVERSITY OF PUERTO RICO" if institution == "INTER-AMERICAN UNIVERSITY OF PUERTO RICO"
	replace institution = "INTERNATIONAL LONGEVITY CENTER-USA" if institution == "INTERNATIONAL LONGEVITY CENTER - USA"
	replace institution = "J CRAIG VENTER INSTITUTE INC" if institution == "J. CRAIG VENTER INSTITUTE"
	replace institution = "JACKSON MEMORIAL HOSPITAL" if institution == "JACKSON MEMORIAL FOUNDATION, INC."
	replace institution = "JAEB CENTER FOR HEALTH RESEARCH INC" if institution == "JAEB CENTER FOR HEALTH RESEARCH"
	replace institution = "JOHN B. PIERCE LABORATORY, INC." if institution == "THE JOHN B. PIERCE LABORATORY, INC."
	replace institution = "JOHNS HOPKINS UNIVERSITY" if institution == "THE JOHNS HOPKINS UNIVERSITY"
	replace institution = "JOHNSON C SMITH UNIVERSITY" if institution == "JOHNSON C. SMITH UNIVERSITY"
	replace institution = "JUDGE BAKER CHILDRENS CENTER" if institution == "JUDGE BAKER CHILDREN'S CENTER"
	replace institution = "JUSTICE RESOURCE INSTITUTE" if institution == "JUSTICE RESOURCE INSTITUTE, INC."
	replace institution = "KANSAS CITY UNIVERSITY OF MEDICINE AND BIOSCIENCES" if institution == "UNIVERSITY OF HEALTH SCIENCES"
	replace institution = "KECK GRADUATE INSTITUTE OF APPLIED LIFE SCIENCESS" if institution == "KECK GRADUATE INSTITUTE OF APPLIED LIFE SCIENCES"
	replace institution = "KENNEDY KRIEGER RESEARCH INSTITUTE" if institution == "KENNEDY KRIEGER RESEARCH INSTITUTE, INC."
	replace institution = "KENNESAW STATE UNIVERSITY" if institution == "KENNESAW COLLEGE"
	replace institution = "KENT STATE UNIVERSITY AT KENT" if institution == "KENT STATE UNIVERSITY"
	replace institution = "KINGS COLLEGE" if institution == "KING'S COLLEGE"
	replace institution = "KLINE INSTITUTE FOR PSYCHIATRIC RESEARCH" if institution == "KLINE RESEARCH CENTER"
	replace institution = "LA CLINICA DE LA RAZA INC" if institution == "LA CLINICA DE LA RAZA"
	replace institution = "LA CLINICA DEL PUEBLO INC" if institution == "LA CLINICA DEL PUEBLO"
	replace institution = "LA FRONTERA CENTER INC" if institution == "LA FRONTERA CENTER, INC."
	replace institution = "LA JOLLA INSTITUTE FOR ALLERGY & IMMUNOLOGY" if institution == "LA JOLLA INSTITUTE FOR ALLERGY AND IMMUNOLOGY"
	replace institution = "LAKEVIEW CENTER INC" if institution == "LAKEVIEW CENTER, INC."
	replace institution = "LAMAR UNIVERSITY AT BEAUMONT" if institution == "LAMAR UNIVERSITY SYSTEM"
	replace institution = "LANKENAU INSTITUTE FOR MEDICAL RESEARCH" if institution == "LANKENAU INSTITUTE FOR MEDICAL RESEARCH, INC"
	replace institution = "LEHIGH UNIVERSITY" if institution == "LEIGH HIGH UNIVERSITY"
	replace institution = "LIBERTY UNIVERSITY INC" if institution == "LIBERTY UNIVERSITY"
	replace institution = "LOS ANGELES BIOMEDICAL RESEARCH INSTITUTE (HARBOR UCLA MEDICAL CENTER)" if institution == "LOS ANGELES BIOMEDICAL RESEARCH INSTITUTE"
	replace institution = "LOUISIANA STATE UNIVERSITY AGRICULTURAL AND MECHANICAL COLLEGE AT BATON ROUGE" if institution == "LOUISIANA STATE UNIVERSITY"
	replace institution = "LOUISIANA STATE UNIVERSITY AT SHREVEPORT" if institution == "LOUISIANA STATE UNIVERSITY AT SHREVEPORT CAMPUS"
	replace institution = "LOUISIANA STATE UNIVERSITY HEALTH SCIENCES CENTER AT NEW ORLEANS" if institution == "LOUISIANA STATE UNIVERSITY MEDICAL CENTER"
	replace institution = "LOYOLA COLLEGE IN MARYLAND" if institution == "LOYOLA COLLEGE"
	replace institution = "LOYOLA UNIVERSITY IN NEW ORLEANS" if institution == "LOYOLA UNIVERSITY"
	replace institution = "LOYOLA UNIVERSITY MEDICAL CENTER" if institution == "LOYOLA UNIVERSITY OF CHICAGO"
	replace institution = "MAINE GENERAL MEDICAL CENTER" if institution == "MAINEGENERAL HEALTH"
	replace institution = "MANSFIELD UNIVERSITY OF PENNSYLVANIA" if institution == "MANSFIELD UNIVERSITY"
	replace institution = "MARY IMOGENE BASSETT HOSPITAL" if institution == "BASSETT HEALTHCARE"
	replace institution = "MARYLAND MEDICAL RESEARCH INSTITUTE, INC" if institution == "MARYLAND MEDICAL RESEARCH INSTITUTE, INC."
	replace institution = "MASSACHUSETTS COLLEGE OF PHARMACY AND HEALTH SCIENCES" if institution == "MASS COLLEGE OF PHARMACY AND ALLIED HEALTH SERVICE"
	replace institution = "MASSACHUSETTS INSTITUTE OF TECHNOLOGY" if institution == "MASSACHUSETTSETTS INSTITUTE OF TECHNOLOGY"
	replace institution = "MASSACHUSETTS INSTITUTE OF TECHNOLOGY" if institution == "MASSACHUSETTS INSTITUTE OF TECHNOLOGY (CORRECTED COPY)"
	replace institution = "MASSACHUSETTS MENTAL HEALTH CENTER" if institution == "MASSACHUSETTS MENTAL HEALTH RESEARCH CORPORATION"
	replace institution = "MATRIX INSTITUTE ON ADDICTIONS INC" if institution == "MATRIX INSTITUTE ON ADDICTIONS, INC."
	replace institution = "MAYO CLINIC COLLEGE OF MEDICINE" if institution == "MAYO CLINIC ROCHESTER"
	replace institution = "MAYO CLINIC COLLEGE OF MEDICINE (ARIZONA)" if institution == "MAYO CLINIC ARIZONA"
	replace institution = "MAYO CLINIC COLLEGE OF MEDICINE (FLORIDA)" if institution == "MAYO CLINIC JACKSONVILLE"
	replace institution = "MC NEESE STATE UNIVERSITY" if institution == "MCNEESE STATE UNIVERSITY"
	replace institution = "MCGUIRE RESEARCH INSTITUTE INC" if institution == "MCGUIRE RESEARCH INSTITUTE, INC."
	replace institution = "MEDICAL TECHNOLOGY AND PRACTICE PATTERNS" if institution == "MEDICAL TECHNOLOGY AND PRACTICE PATTERNS INSTITUTE"
	replace institution = "MEDLANTIC RESEARCH INSTITUTE" if institution == "MEDSTAR RESEARCH INSTITUTE"
	replace institution = "MEMORIAL HEALTH UNIVERSITY MEDICAL CENTER INC" if institution == "MEMORIAL HEALTH UNIVERSITY MEDICAL CENTER, INC."
	replace institution = "MEMORIAL SLOAN KETTERING CANCER CENTER" if institution == "SLOAN-KETTERING INSTITUTE FOR CANCER RESEARCH"
	replace institution = "MENTAL HEALTH SYSTEMS INC" if institution == "MENTAL HEALTH SYSTEMS, INC."
	replace institution = "MERCER UNIVERSITY AT MACON" if institution == "MERCER UNIVERSITY"
	replace institution = "MERCY HOSPITAL AND MEDICAL CENTER (DES MOINES)" if institution == "MERCY HOSPITAL MEDICAL CENTER"
	replace institution = "METHODIST HOSPITAL RESEARCH INSTITUTE" if institution == "THE METHODIST HOSPITAL RESEARCH INSTITUTE"
	replace institution = "METROPOLITAN STATE UNIVERSITY OF DENVER" if institution == "METROPOLITAN STATE COLLEGE"
	replace institution = "MIAMI CHILDRENS HOSPITAL (MIAMI, FL)" if institution == "MIAMI CHILDREN'S HOSPITAL"
	replace institution = "MIAMI UNIVERSITY AT OXFORD" if institution == "MIAMI UNIVERSITY"
	replace institution = "MID-HUDSON FAMILY HEALTH INSTITUTE" if institution == "MID HUDSON FAMILY HEALTH INSTITUTE, INC."
	replace institution = "MINNESOTA STATE UNIVERSITY AT MOOREHEAD" if institution == "MINNESOTA STATE UNIVERSITY MOOREHEAD"
	replace institution = "MIRIAM HOSPITAL" if institution == "THE MIRIAM"
	replace institution = "MISERICORDIA UNIVERSITY" if institution == "COLLEGE MISERICORDIA"
	replace institution = "MONTANA STATE UNIVERSITY AT BILLINGS" if institution == "MONTANA STATE UNIVERSITY, BILLINGS"
	replace institution = "MOUNT SAINT MARYS COLLEGE" if institution == "MOUNT ST. MARY'S COLLEGE"
	replace institution = "MOUNT SINAI MEDICAL CENTER (MIAMI BEACH)" if institution == "MOUNT SINAI MEDICAL CENTER OF GREATER MIAMI"
	replace institution = "MOUNTAIN STATES GROUP INC" if institution == "MOUNTAIN STATES GROUP, INC."
	replace institution = "MRI INSTITUTE FOR BIOMEDICAL RESEARCH" if institution == "THE MAGNETIC RESONANCE IMAGING INSTITUTE"
	replace institution = "MT ASCUTNEY HOSPITAL AND HEALTH CENTER" if institution == "MT. ASCUTNEY HOSPITAL"
	replace institution = "NARROWS INSTITUTE FOR BIOMEDICAL RESEARCH INC" if institution == "NARROWS INSTITUTE FOR BIOMEDICAL RESEARCH, INC."
	replace institution = "NATIONAL BIOMEDICAL RESEARCH FOUNDATION" if institution == "NATIONAL BIOMEDICAL RESEARCH FOUNDATION, INC."
	replace institution = "NATIONAL CENTER FOR GENOME RESOURCES" if institution == "NATIONAL CENTER FOR GENOME RESOURCES (NCGR)"
	replace institution = "NATIONAL DEVELOPMENT AND RESEARCH INSTITUTES" if institution == "NATIONAL DEVELOPMENT AND RESEARCH INSTITUTES, INC."
	replace institution = "NATIVE AMERICAN COMMUNITY HEALTH CENTER" if institution == "NATIVE AMERICAN COMMUNITY HEALTH CENTER, INC."
	replace institution = "NEW MEXICO STATE UNIVERSITY AT LAS CRUCES" if institution == "NEW MEXICO STATE UNIVERSITY"
	replace institution = "NEW YORK BLOOD CENTER" if institution == "NEW YORK BLOOD CENTER, INC."
	replace institution = "NEW YORK STATE PSYCHIATRIC INSTITUTE" if institution == "NEW YORK PSYCHIATRIC INSTITUTE"
	replace institution = "NEW YORK STRUCTURAL BIOLOGY CENTER" if institution == "THE NEW YORK STRUCTURAL BIOLOGY CENTER, INC."
	replace institution = "NEW YORK UNIVERSITY MEDICAL CENTER" if institution == "NEW YORK UNIVERSITY SCHOOL OF MEDICINE"
	replace institution = "NEW YORK UNIVERSITY TANDON SCHOOL OF ENGINEERING" if institution == "POLYTECHNIC UNIVERSITY"
	replace institution = "NORTH CARE" if institution == "NORTH CARE CENTER"
	replace institution = "NORTH CAROLINA AGRICULTURAL AND TECHNICAL STATE UNIVERSITY" if institution == "NORTH CAROLINA AGRICULTURAL AND TECHNICAL"
	replace institution = "NORTH CAROLINA STATE UNIVERSITY AT RALEIGH" if institution == "NORTH CAROLINA STATE UNIVERSITY"
	replace institution = "NORTH SHORE - LONG ISLAND JEWISH MEDICAL CENTER" if institution == "NORTH SHORE - LONG ISLAND JEWISH HEALTH SYSTEM"
	replace institution = "NORTH SHORE - LONG ISLAND JEWISH MEDICAL CENTER" if institution == "NORTH SHIRE LONG ISLAND JEWISH HEALTH SYSTEM"
	replace institution = "NOTRE DAME DE NAMUR UNIVERSITY" if institution == "COLLEGE OF NOTRE DAME"
	replace institution = "NOTRE DAME OF MARYLAND UNIVERSITY" if institution == "COLLEGE OF NOTRE DAME OF MARYLAND"
	replace institution = "OHIO UNIVERSITY AT ATHENS" if institution == "OHIO UNIVERSITY"
	replace institution = "OLD DOMINION UNIVERSITY" if institution == "OLD DOMINION UNIVERSITY RESEARCH FOUNDATION"
	replace institution = "ORDWAY RESEARCH INSTITUTE INC" if institution == "ORDWAY RESEARCH INSTITUTE, INC."
	replace institution = "OREGON HEALTH AND SCIENCE UNIVERSITY" if institution == "OREGON HEALTH SCIENCES UNIVERSITY"
	replace institution = "OREGON SOCIAL LEARNING CENTER, INC." if institution == "OREGON SOCIAL LEARNING CENTER"
	replace institution = "ORLANDO REGIONAL HEALTHCARE SYSTEM INC" if institution == "ORLANDO REGIONAL HEALTHCARE SYSTEM"
	replace institution = "PACIFIC TUBERCULOSIS AND CANCER RESEARCH ORGANIZATION" if institution == "PACIFIC TUBERCULOSIS AND CANCER RESEARCH"
	replace institution = "PALMER CHIROPRACTIC UNIVERSITY" if institution == "PALMER CHIROPRACTIC UNIVERSITY FOUNDATION"
	replace institution = "PENNSYLVANIA STATE UNIVERSITY AT UNIVERSITY PARK" if institution == "THE PENNSYLVANIA STATE UNIVERSITY"
	replace institution = "PENNSYLVANIA STATE UNIVERSITY AT UNIVERSITY PARK" if institution == "PENNSYLVANIA STATE UNIVERSITY"
	replace institution = "PENNSYLVANIA STATE UNIVERSITY HERSHEY MEDICAL CENTER" if institution == "HERSHEY MEDICAL CENTER"
	replace institution = "PHILADELPHIA HEALTH AND EDUCATION CORPORATION" if institution == "THE HEALTH FEDERATION OF PHILADELPHIA, INC."
	replace institution = "PLYMOUTH STATE UNIVERSITY" if institution == "PLYMOUTH STATE COLLEGE OF THE UNIVERSITY SYSTEM"
	replace institution = "PROVIDENCE PORTLAND MEDICAL CENTER" if institution == "PROVIDENCE MEDICAL CENTER"
	replace institution = "PROVIDENCE SAINT VINCENT MEDICAL CENTER" if institution == "PROVIDENCE ST. VINCENT MEDICAL CENTER"
	replace institution = "PUBLIC HEALTH FOUNDATION ENTERPRISES" if institution == "PUBLIC HEALTH FOUNDATION ENTERPRISES, INC."
	replace institution = "PUBLIC HEALTH RESEARCH INSTITUTE OF THE CITY OF NEW YORK" if institution == "PUBLIC HEALTH RESEARCH INSTITUTE"
	replace institution = "PURDUE UNIVERSITY AT WEST LAFAYETTE" if institution == "PURDUE UNIVERSITY"
	replace institution = "QUINNIPIAC UNIVERSITY" if institution == "QUINNIPIAC COLLEGE"
	replace institution = "REGENSTRIEF INSTITUTE" if institution == "REGENSTRIEF INSTITUTE, INC."
	replace institution = "REHABILITATION INSTITUTE OF CHICAGO" if institution == "REHABILITATION INSTITUTE RESEARCH CORPORATION"
	replace institution = "RESEARCH CENTER FOR HEALTH CARE DECISION MAKING" if institution == "RESEARCH CENTER FOR HEALTH CARE DECISION-MAKING"
	replace institution = "RESEARCH FOUNDATION FOR MENTAL HYGIENE" if institution == "RESEARCH FOUNDATION FOR MENTAL HYGIENE, INC."
	replace institution = "RHODE ISLAND HOSPITAL" if institution == "RHODE ISLAND HOSPITAL/LIFESPAN"
	replace institution = "RICHARD STOCKTON COLLEGE OF NEW JERSEY" if institution == "THE RICHARD STOCKTON COLLEGE OF NEW JERSEY"
	replace institution = "ROCKEFELLER UNIVERSITY" if institution == "ROCKEFELLER UNIVERSITY HOSPITAL"
	replace institution = "ROSALIND FRANKLIN UNIVERSITY OF MEDICINE AND SCIENCE" if institution == "UNIVERSITY OF HEALTH SCIENCES/CHICAGO MEDICAL SCHOOL"
	replace institution = "ROSKAMP INSTITUTE INC" if institution == "ROSKAMP INSTITUTE"
	replace institution = "ROWAN UNIVERSITY" if institution == "ROWAN COLLEGE OF NEW JERSEY"
	replace institution = "RUMBAUGH-GOODWIN INSTITUTE FOR CANCER RESEARCH INC" if institution == "RUMBAUGH-GOODWIN INSTITUTE FOR CANCER RESEARCH,INC"
	replace institution = "RUTGERS UNIVERSITY AT NEW BRUNSWICK" if institution == "RUTGERS UNIVERSITY"
	replace institution = "SAGINAW VALLEY STATE UNIVERSITY" if institution == "SAGINAW VALLEY STATE COLLEGE"
	replace institution = "SAINT AUGUSTINES COLLEGE" if institution == "SAINT AUGUSTINE'S COLLEGE"
	replace institution = "SAINT BARNABAS HOSPITAL" if institution == "ST. BARNABAS HOSPITAL"
	replace institution = "SAINT CLOUD STATE UNIVERSITY" if institution == "ST. CLOUD STATE UNIVERSITY"
	replace institution = "SAINT ELIZABETHS MEDICAL CENTER OF BOSTON" if institution == "ST. ELIZABETH'S MEDICAL CENTER OF BOSTON"
	replace institution = "SAINT FRANCIS REGIONAL MEDICAL CENTER" if institution == "VIA CHRISTI REGIONAL MEDICAL CENTER, INC. (FORMERLY ST. FRANCIS REGIONAL MEDICAL CENTER)"
	replace institution = "SAINT JOHNS HOSPITAL (SPRINGFIELD IL)" if institution == "ST. JOHN'S REGIONAL HEALTH CENTER"
	replace institution = "SAINT JOSEPH MERCY AT OAKLAND" if institution == "ST. JOSEPH MERCY OAKLAND"
	replace institution = "SAINT JOSEPH MERCY HEALTH SYSTEM" if institution == "ST. JOSEPH MERCY HOSPITAL"
	replace institution = "SAINT JOSEPHS HOSPITAL AND MEDICAL CENTER (PHOENIX)" if institution == "ST. JOSEPH'S HOSPITAL AND MEDICAL CENTER"
	replace institution = "SAINT JOSEPHS UNIVERSITY" if institution == "ST. JOSEPH'S UNIVERSITY"
	replace institution = "SAINT JUDE CHILDRENS RESEARCH HOSPITAL" if institution == "SAINT JUDE CHILDREN'S RESEARCH HOSPITAL"
	replace institution = "SAINT LAWRENCE UNIVERSITY" if institution == "ST. LAWRENCE UNIVERSITY"
	replace institution = "SAINT LOUIS UNIVERSITY" if institution == "ST. LOUIS UNIVERSITY"
	replace institution = "SAINT LUKES HOSPITAL" if institution == "SAINT LUKE'S HOSPITAL OF KANSAS CITY"
	replace institution = "SAINT LUKES HOSPITAL (MILWAUKEE WI)" if institution == "AURORA HEALTH CARE, INC."
	replace institution = "SAINT LUKES-ROOSEVELT HOSPITAL CENTER" if institution == "ST. LUKE'S ROOSEVELT HOSPITAL CENTER"
	replace institution = "SAINT MARYS COLLEGE" if institution == "ST. MARY COLLEGE"
	replace institution = "SAINT MARYS COLLEGE OF MARYLAND" if institution == "ST. MARY'S COLLEGE OF MARYLAND"
	replace institution = "SAINT MARYS UNIVERSITY" if institution == "ST. MARY'S UNIVERSITY OF SAN ANTONIO"
	replace institution = "SAINT MICHAELS COLLEGE" if institution == "SAINT MICHAEL'S COLLEGE"
	replace institution = "SAINT NORBERT COLLEGE" if institution == "ST. NORBERT COLLEGE"
	replace institution = "SAINT OLAF COLLEGE" if institution == "ST. OLAF COLLEGE"
	replace institution = "SAINT PAULS COLLEGE" if institution == "SAINT PAUL'S COLLEGE"
	replace institution = "SAINT VINCENT COLLEGE" if institution == "ST. VINCENT COLLEGE CORPORATION"
	replace institution = "SALEM STATE UNIVERSITY" if institution == "SALEM STATE COLLEGE"
	replace institution = "SALISBURY UNIVERSITY" if institution == "SALISBURY STATE UNIVERSITY"
	replace institution = "SAN DIEGO STATE UNIVERSITY" if institution == "SAN DIEGO STATE UNIVERSITY FOUNDATION"
	replace institution = "SAN JOSE STATE UNIVERSITY" if institution == "SAN JOSE STATE UNIVERSITY AND THE FOUNDATION"
	replace institution = "SAVANNAH STATE UNIVERSITY" if institution == "SAVANNAH STATE COLLEGE"
	replace institution = "SCHEPENS EYE RESEARCH INSTITUTE" if institution == "SCHEPENS EYE RESEARCH INSTITUTE, INC."
	replace institution = "SCREENING FOR MENTAL HEALTH INC" if institution == "SCREENING FOR MENTAL HEALTH, INC."
	replace institution = "SHEPPARD PRATT HEALTH SYSTEM INC" if institution == "SHEPPARD PRATT HEALTH SYSTEMS, INC."
	replace institution = "SHIPPENSBURG UNIVERSITY OF PENNSYLVANIA" if institution == "SHIPPENSBURG UNIVERSITY"
	replace institution = "SHIPPENSBURG UNIVERSITY OF PENNSYLVANIA" if institution == "SHIPPENBURG UNIVERSITY"
	replace institution = "SINGING RIVER HEALTH SYSTEM" if institution == "SINGING RIVER HOSPITAL"
	replace institution = "SLIPPERY ROCK UNIVERSITY OF PENNSYLVANIA" if institution == "SLIPPERY ROCK UNIVERSITY"
	replace institution = "SMITH-KETTLEWELL EYE RESEARCH INSTITUTE" if institution == "SMITH-KETTLEWELL EYE RESEARCH FOUNDATION"
	replace institution = "SMITHSONIAN ASTROPHYSICAL OBSERVATORY" if institution == "SMITHSONIAN INSTITUTION - SMITHSONIAN ASTROPHYSICAL INSTITUTION"
	replace institution = "SONOMA STATE UNIVERSITY" if institution == "SONOMA STATE UNIVERSITY ACADEMIC FOUNDATION"
	replace institution = "SOUTHERN NEVADA CANCER RESEARCH FOUNDATION" if institution == "NEVADA CANCER RESEARCH FOUNDATION"
	replace institution = "SOUTHERN UNIVERSITY AGRICULTURAL AND MECHANICAL COLLEGE AT BATON ROUGE" if institution == "SOUTHERN UNIVERSITY"
	replace institution = "SOUTHWESTERN VERMONT HEALTH CARE CORP" if institution == "SOUTHWESTERN VERMONT HEALTH CARE CORPORATION"
	replace institution = "SPECTRUM HEALTH HOSPITALS" if institution == "SPECTRUM HEALTH - DOWNTOWN CAMPUS"
	replace institution = "ST JOHNS MERCY MEDICAL CENTER" if institution == "ST. JOHNS MERCY MEDICAL CENTER"
	replace institution = "ST VINCENT HEALTHCARE" if institution == "ST. VINCENT HEALTHCARE FOUNDATION"
	replace institution = "ST VINCENT MEDICAL CENTER" if institution == "ST. VINCENT MERCY MEDICAL CENTER"
	replace institution = "ST. LUKE'S HOSPITALS-MERITCARE" if institution == "ST. LUKES HOSPITALS - MERITCARE"
	replace institution = "STEPHEN F AUSTIN STATE UNIVERSITY" if institution == "STEPHEN F. AUSTIN STATE UNIVERSITY"
	replace institution = "STOWERS INSTITUTE FOR MEDICAL RESEARCH" if institution == "STOWERS INSTITUTE"
	replace institution = "SUNY - POLYTECHNIC INSTITUTE" if institution == "RFSUNY - UTICA/ROME COLLEGE"
	replace institution = "SWEDISH MEDICAL CENTER, FIRST HILL" if institution == "SWEDISH MEDICAL CENTER"
	replace institution = "TARZANA TREATMENT CENTERS INC" if institution == "TARZANA TREATMENT CENTER"
	replace institution = "TEXAS AGRICULTURAL AND MECHANICAL BAYLOR COLLEGE OF DENTISTRY" if institution == "BAYLOR COLLEGE OF DENTISTRY" 
	replace institution = "TEXAS AGRICULTURAL AND MECHANICAL UNIVERSITY AT COMMERCE" if institution == "EAST TEXAS STATE UNIVERSITY"
	replace institution = "TEXAS CHILDRENS HOSPITAL" if institution == "TEXAS CHILDREN'S HOSPITAL"
	replace institution = "TEXAS STATE UNIVERSITY AT SAN MARCOS" if institution == "SOUTHWEST TEXAS STATE UNIVERSITY"
	replace institution = "TEXAS WOMANS UNIVERSITY" if institution == "TEXAS WOMAN'S UNIVERSITY"
	replace institution = "THE HOPE HEART INSTITUTE" if institution == "HOPE HEART INSTITUTE"
	replace institution = "THE NEW SCHOOL" if institution == "NEW SCHOOL UNIVERSITY"
	replace institution = "THE WILLIAM PATERSON UNIVERSITY OF NEW JERSEY" if institution == "THE WILLIAM PATERSON COLLEGE OF NEW JERSEY"
	replace institution = "TREATMENT RESEARCH INSTITUTE, INC. (TRI)" if institution == "TREATMENT RESEARCH INSTITUTE"
	replace institution = "TRINITY COLLEGE (CONNECTICUT)" if institution == "TRINITY COLLEGE - CONNECTICUT"
	replace institution = "TROY STATE UNIVERSITY" if institution == "TROY STATE UNIVERSITY SYSTEM"
	replace institution = "TRUDEAU INSTITUTE INC" if institution == "TRUDEAU INSTITUTE, INC."
	replace institution = "TRUE RESEARCH FOUNDATION" if institution == "T.R.U.E. RESEARCH FOUNDATION"
	replace institution = "TRUMAN MEDICAL CENTER" if institution == "TRUMAN MEDICAL CENTER, INC."
	replace institution = "TRUMAN STATE UNIVERSITY" if institution == "NORTHEAST MISSOURI STATE UNIVERSITY"
	replace institution = "TUBA CITY REGIONAL HEALTH CARE CORP" if institution == "TUBA CITY REGIONAL HEALTH CARE CORP."
	replace institution = "TUFTS UNIVERSITY AT MEDFORD" if institution == "TUFTS UNIVERSITY"
	replace institution = "TUFTS-NEW ENGLAND MEDICAL CENTER" if institution == "NEW ENGLAND MEDICAL CENTER"
	replace institution = "TULANE UNIVERSITY OF LOUISIANA" if institution == "TULANE UNIVERSITY"
	replace institution = "UNIVERSITY OF ALABAMA AT TUSCALOOSA" if institution == "UNIVERSITY OF ALABAMA"
	replace institution = "UNIVERSITY OF ALASKA SYSTEM" if institution == "UNIVERSITY OF ALASKA"
	replace institution = "UNIVERSITY OF ARKANSAS AT FAYETTEVILLE" if institution == "UNIVERSITY OF ARKANSAS"
	replace institution = "UNIVERSITY OF ARKANSAS MEDICAL SCIENCES AT LITTLE ROCK" if institution == "UNIVERSITY OF ARKANSAS FOR MEDICAL SCIENCES"
	replace institution = "UNIVERSITY OF CALIFORNIA AT SANTA BARBARA" if institution == "UNIVERSITY OF CALIFORNIA AT SANTA CLARA"
	replace institution = "UNIVERSITY OF COLORADO DENVER HEALTH SCIENCES CENTER" if institution == "UNIVERSITY OF COLORADO HEALTH SCIENCES CENTER"
	replace institution = "UNIVERSITY OF COLORADO DENVER HEALTH SCIENCES CENTER" if institution == "UNIVERSITY OF COLORADO AT DENVER"
	replace institution = "UNIVERSITY OF CONNECTICUT AT STORRS" if institution == "UNIVERSITY OF CONNECTICUT"
	replace institution = "UNIVERSITY OF CONNECTICUT SCHOOL OF MEDICINE AND DENTISTRY" if institution == "UNIVERSITY OF CONNECTICUT SCIENCE HEALTH CENTER"
	replace institution = "UNIVERSITY OF CONNECTICUT SCHOOL OF MEDICINE AND DENTISTRY" if institution == "UNIVERSITY OF CONNECTICUT HEALTH CENTER"
	replace institution = "UNIVERSITY OF FINDLAY" if institution == "THE UNIVERSITY OF FINDLAY"
	replace institution = "UNIVERSITY OF GEORGIA" if institution == "UNIVERSITY OF GEORGIA RESEARCH FOUNDATION, INC."
	replace institution = "UNIVERSITY OF HOUSTON AT CLEAR LAKE CITY" if institution == "UNIVERSITY OF HOUSTON AT CLEAR LAKE"
	replace institution = "UNIVERSITY OF ILLINOIS AT CHICAGO" if institution == "THE UNIVERSITY OF ILLINOIS AT CHICAGO"
	replace institution = "UNIVERSITY OF ILLINOIS AT SPRINGFIELD" if institution == "UNIERSITY OF ILLINOIS AT SPRINGFIELD"
	replace institution = "UNIVERSITY OF ILLINOIS AT URBANA-CHAMPAIGN" if institution == "UNIVERSITY OF ILLINOIS AT URBANA CHAMPAIGN"
	replace institution = "UNIVERSITY OF KANSAS AT LAWRENCE" if institution == "UNIVERSITY OF KANSAS"
	replace institution = "UNIVERSITY OF LOUISIANA AT LAFAYETTE" if institution == "UNIVERSITY OF LOUISIANA LAFAYATTE"
	replace institution = "UNIVERSITY OF MAINE" if institution == "UNIVERSITY OF MAINE SYSTEM"
	replace institution = "UNIVERSITY OF MARYLAND - CENTER FOR ENVIRONMENTAL AND ESTUARINE STUDIES" if institution == "UNIVERSITY OF MARYLAND CENTER FOR ENVIRONMENTAL SCIENCE"
	replace institution = "UNIVERSITY OF MARYLAND - CENTER FOR ENVIRONMENTAL AND ESTUARINE STUDIES" if institution == "UNIVERSITY OF MARYLAND CENTER FOR ENVIRONMENTAL"
	replace institution = "UNIVERSITY OF MARYLAND AT BALTIMORE COUNTY" if institution == "UNIVERSITY OF MARYLAND BALTIMORE COUNTY"
	replace institution = "UNIVERSITY OF MARYLAND AT COLLEGE PARK" if institution == "UNIVERSITY OF MARYLAND"
	replace institution = "UNIVERSITY OF MASSACHUSETTS AT LOWELL" if institution == "UNIVERSITY OF MASSACHUSETTS LOWELL CAMPUS"
	replace institution = "UNIVERSITY OF MASSACHUSETTS MEDICAL SCHOOL AT WORCESTER" if institution == "UNIVERSITY OF MASSACHUSETTS MEDICAL SCHOOL"
	replace institution = "UNIVERSITY OF MEMPHIS" if institution == "THE UNIVERSITY OF MEMPHIS"
	replace institution = "UNIVERSITY OF MIAMI AT CORAL GABLES" if institution == "UNIVERSITY OF MIAMI"
	replace institution = "UNIVERSITY OF NEW MEXICO AT ALBUQUERQUE" if institution == "UNIVERSITY OF NEW MEXICO"
	replace institution = "UNIVERSITY OF NORTH FLORIDA" if institution == "UNIVERSITY OF NORTH FLORDIA"
	replace institution = "UNIVERSITY OF NORTH TEXAS HEALTH SCIENCE CENTER" if institution == "TEXAS COLLEGE OF OSTEOPATHIC MEDICINE"
	replace institution = "UNIVERSITY OF NOTRE DAME DU LAC" if institution == "UNIVERSITY OF NOTRE DAME"
	replace institution = "UNIVERSITY OF OKLAHOMA AT NORMAN" if institution == "UNIVERSITY OF OKLAHOMA"
	replace institution = "UNIVERSITY OF PITTSBURGH AT PITTSBURGH" if institution == "UNIVERSITY OF PITTSBURGH"
	replace institution = "UNIVERSITY OF PUERTO RICO AT MAYAGUEZ" if institution == "UNIVERSITY OF PUERTO RICO MAYAGUEZ"
	replace institution = "UNIVERSITY OF PUERTO RICO AT RIO PIEDRAS" if institution == "UNIVERSITY OF PUERTO RICO RIO PIEDRAS"
	replace institution = "UNIVERSITY OF SAINT JOSEPH" if institution == "ST. JOSEPH COLLEGE"
	replace institution = "UNIVERSITY OF SAINT THOMAS" if institution == "UNIVERSITY OF ST. THOMAS"
	replace institution = "UNIVERSITY OF SOUTH CAROLINA - CAROLINA COASTAL UNIVERSITY" if institution == "UNIVERSITY OF SOUTH CAROLINA AT COASTAL"
	replace institution = "UNIVERSITY OF SOUTH CAROLINA AT COLUMBIA" if institution == "UNIVERSITY OF SOUTH CAROLINA"
	replace institution = "UNIVERSITY OF SOUTH CAROLINA UPSTATE" if institution == "UNIVERSITY OF SOUTH CAROLINA AT SPARTANBURG"
	replace institution = "UNIVERSITY OF TENNESSEE AT MARTIN" if institution == "UNIVERSITY OF TENNESSEE OF MARTIN"
	replace institution = "UNIVERSITY OF TENNESSEE HEALTH SCIENCE CENTER" if institution == "UNIVERSITY OF TENNESSEE CENTER FOR HEALTH SCIENCES"
	replace institution = "UNIVERSITY OF TEXAS MD ANDERSON CANCER CENTER" if institution == "UNIVERSITY OF TEXAS M. D. ANDERSON CANCER CENTER"
	replace institution = "UNIVERSITY OF TEXAS SOUTHWESTERN MEDICAL CENTER AT DALLAS" if institution == "UNIVERSITY OF TEXAS SOUTHWESTERN"
	replace institution = "UNIVERSITY OF TEXAS-PAN AMERICAN" if institution == "PAN AMERICAN UNIVERSITY"
	replace institution = "UNIVERSITY OF TOLEDO HEALTH SCIENCES CENTER" if institution == "MEDICAL COLLEGE OF OHIO AT TOLEDO"
	replace institution = "UNIVERSITY OF VERMONT AND STATE AGRICULTURAL COLLEGE" if institution == "UNIVERSITY OF VERMONT"
	replace institution = "UNIVERSITY OF VIRGINIA AT CHARLOTTESVILLE" if institution == "UNIVERSITY OF VIRGINIA"
	replace institution = "UNIVERSITY OF WEST GEORGIA" if institution == "STATE UNIVERSITY OF WEST GEORGIA"
	replace institution = "UNIVERSITY OF WISCONSIN AT EAU CLAIRE" if institution == "UNIVERSITY OF WISCONSIN SYSTEM - EAU CLAIRE"
	replace institution = "UNIVERSITY OF WISCONSIN AT GREEN BAY" if institution == "UNIVERSITY OF WISCONSIN SYSTEM - GREEN BAY"
	replace institution = "UNIVERSITY OF WISCONSIN AT LA CROSSE" if institution == "UNIVERSITY OF WISCONSIN SYSTEM - LACROSSE"
	replace institution = "UNIVERSITY OF WISCONSIN AT MADISON" if institution == "UNIVERSITY OF WISCONSIN - EXTENSION"
	replace institution = "UNIVERSITY OF WISCONSIN AT MADISON" if institution == "UNIVERSITY OF WISCONSIN - MADISON AND EXTENSION"
	replace institution = "UNIVERSITY OF WISCONSIN AT MILWAUKEE" if institution == "UNIVERSITY OF WISCONSIN - MILWAUKEE"
	replace institution = "UNIVERSITY OF WISCONSIN AT OSHKOSH" if institution == "UNIVERSITY OF WISCONSIN SYSTEM - OSHKOSH"
	replace institution = "UNIVERSITY OF WISCONSIN AT PARKSIDE" if institution == "UNIVERSITY OF WISCONSIN SYSTEM - PARKSIDE"
	replace institution = "UNIVERSITY OF WISCONSIN AT PLATTEVILLE" if institution == "UNIVERSITY OF WISCONSIN SYSTEM - PLATTEVILLE"
	replace institution = "UNIVERSITY OF WISCONSIN AT RIVER FALLS" if institution == "UNIVERSITY OF WISCONSIN SYSTEM - RIVER FALLS"
	replace institution = "UNIVERSITY OF WISCONSIN AT STEVENS POINT" if institution == "UNIVERSITY OF WISCONSIN SYSTEM - STEVENS POINT"
	replace institution = "UNIVERSITY OF WISCONSIN AT STOUT" if institution == "UNIVERSITY OF WISCONSIN SYSTEM - STOUT"
	replace institution = "UNIVERSITY OF WISCONSIN AT SUPERIOR" if institution == "UNIVERSITY OF WISCONSIN SYSTEM - SUPERIOR"
	replace institution = "UNIVERSITY OF WISCONSIN AT WHITEWATER" if institution == "UNIVERSITY OF WISCONSIN SYSTEM - WHITEWATER"
	replace institution = "UNIVERSITY OF WISCONSIN - RESEARCH CENTERS" if institution == "UNIVERSITY OF WISCONSIN SYSTEM - CENTERS"
	replace institution = "UNIVERSITYERSIDAD CENTRAL DEL CARIBE" if institution == "UNIVERSIDAD CENTRAL DEL CARIBE"
	replace institution = "UPMC CHILDRENS HOSPITAL OF PITTSBURGH" if institution == "CHILDREN'S HOSPITAL OF PITTSBURGH"
	replace institution = "UPMC MCKEESPORT HOSPITAL" if institution == "UPMC - MCKEESPORT HOSPITAL"
	replace institution = "UMPC MAGEE-WOMEN'S HOSPITAL" if institution == "MAGEE-WOMENS HEALTH CORPORATION"
	replace institution = "VETERANS BIOMEDICAL RESEARCH INSTITUTE" if institution == "VETERANS BIO-MEDICAL RESEARCH INSTITUTE, INC."
	replace institution = "VETERANS MEDICAL RESEARCH FOUNDATION OF SAN DIEGO" if institution == "VETERANS MEDICAL RESEARCH FOUNDATION"
	replace institution = "VIRGINIA MILITARY INSTITUTE" if institution == "VIRGINIA MILITARY INSTITUTE RESEARCH LABORATORIES"
	replace institution = "VIRGINIA MILITARY INSTITUTE" if institution == "VIRGINIA MILITARY INSTITUTE RESEARCH LABORATORIES (VMIRL)"
	replace institution = "VIRGINIA POLYTECHNIC INSTITUTE AND STATE UNIVERSITY" if institution == "VIRGINIA TECH"
	replace institution = "VIRGINIA POLYTECHNIC INSTITUTE AND STATE UNIVERSITY" if institution == "VIRGINIA POLYTECHNIC INSTITUTE"
	replace institution = "VTT/MSI MOLECULAR SCIENCE INSTITUTE" if institution == "MOLECULAR SCIENCES INSTITUTE"
	replace institution = "WADSWORTH CENTER" if institution == "WADSWORTH CENTER FOR LABORATORIES AND RESEARCH"
	replace institution = "WAKE FOREST UNIVERSITY" if institution == "BOWMAN GRAY SCHOOL OF MEDICINE"
	replace institution = "WASHBURN UNIVERSITY" if institution == "WASHBURN UNIVERSITY OF TOPEKA"
	replace institution = "WEBER STATE UNIVERSITY" if institution == "WEBER STATE COLLEGE"
	replace institution = "WELL-BEING INSTITUTE INC" if institution == "WELL-BEING INSTITUTE"
	replace institution = "WENTWORTH INSTITUTE OF TECHNOLOGY INC" if institution == "WENTWORTH INSTITUTE OF TECHNOLOGY"
	replace institution = "WENTWORTH INSTITUTE OF TECHNOLOGY INC" if institution == "WENTWORTH INSTITUTE"
	replace institution = "WEST CHESTER UNIVERSITY OF PENNSYLVANIA" if institution == "WEST CHESTER UNIVERSITY"
	replace institution = "WEST LIBERTY UNIVERSITY" if institution == "WEST LIBERTY STATE COLLEGE"
	replace institution = "WESTCHESTER COUNTY MEDICAL CENTER" if institution == "WESTCHESTER MEDICAL CENTER"
	replace institution = "WESTERN NEW ENGLAND UNIVERSITY" if institution == "WESTERN NEW ENGLAND COLLEGE"
	replace institution = "WESTERN PENNSYLVANIA HOSPITAL" if institution == "THE WESTERN PENNSYLVANIA HOSPITAL FOUNDATION"
	replace institution = "WHITMAN WALKER HEALTH" if institution == "WHITMAN-WALKER CLINIC, INC."
	replace institution = "WILLIAMS COLLEGE" if institution == "WILLLIAMS COLLEGE"
	replace institution = "WILLS EYE HOSPITAL (PHILADELPHIA)" if institution == "WILLS EYE HOSPITAL"
	replace institution = "WINSTON-SALEM STATE UNIVERSITY" if institution == "WINSTON-SALEM UNIVERSITY"
	replace institution = "WINTHROP-UNIVERSITY HOSPITAL" if institution == "WINTHROP UNIVERSITY HOSPITAL"
	replace institution = "WISTAR INSTITUTE" if institution == "THE WISTAR INSTITUTE OF ANATOMY AND BIOLOGY"
	replace institution = "WOMEN AND INFANTS HOSPITAL-RHODE ISLAND" if institution == "WOMEN AND INFANTS' HOSPITAL"
	replace institution = "WOOD HUDSON CANCER RESEARCH LAB INC" if institution == "WOOD HUDSON CANCER RESEARCH LABORATORY"
	replace institution = "WOODS HOLE OCEANOGRAPHIC INSTITUTE" if institution == "WOODS HOLE OCEANOGRAPHIC INSTITUTION"
	replace institution = "YALE-NEW HAVEN HOSPITAL" if institution == "YALE NEW HAVEN HEALTH"

	// ----- more complex changes based on other fields as well as institution name ----- // 
	replace institution = "CHILDREN'S RESEARCH INSTITUTE (WASHINGTON, DC)" if institution == "CHILDREN'S RESEARCH INSTITUTE" & city == "WASHINGTON"
	replace institution = "CHILDREN'S RESEARCH INSTITUTE (COLUMBUS, OH)" if institution == "CHILDREN'S RESEARCH INSTITUTE" & city == "COLUMBUS"
	replace institution = "LINCOLN UNIVERSITY (JEFFERSON CITY)" if institution == "LINCOLN UNIVERSITY" & city == "JEFFERSON CITY" 
	replace institution = "LINCOLN UNIVERSITY (LINCOLN UNIVERSITY PA)" if institution == "LINCOLN UNIVERSITY" & city == "LINCOLN UNIVERSITY" 
	replace institution = "SAINT JOHNS UNIVERSITY (COLLEGEVILLE)" if institution == "ST. JOHN'S UNIVERSITY" & city == "COLLEGEVILLE" 
	replace institution = "SAINT JOHNS UNIVERSITY (QUEENS)" if institution == "ST. JOHN'S UNIVERSITY" & city == "JAMAICA" 
	replace institution = "UMDNJ - ROBERT WOOD JOHNSON MEDICAL SCHOOL" if institution == "UNIVERSITY OF MEDICINE AND DENTISTRY OF NEW JERSEY" & city == "NEW BRUNSWICK"
	replace institution = "UNIVERSITY OF TENNESSEE AT KNOXVILLE" if institution == "UNIVERSITY OF TENNESSEE" & city == "KNOXVILLE"
	replace institution = "UNIVERSITY OF TENNESSEE HEALTH SCIENCE CENTER" if institution == "UNIVERSITY OF TENNESSEE" & city == "MEMPHIS"

	// ----- final standardization - strip punctuation ----- //
	replace institution = subinstr(institution, "'", "", .)

	// ----- save ----- //
	trim_subroutine
	save "${nih_output}/nicra_panel.dta", replace
	clear

/* ------------------------------- Begin Note ------------------------------- // 

	Operation 03: Subset the data. 
	
	Using supplementary cgaf data, we isolate a set of "important" institutions, 
	which we are calling "relevant" institutions. We define relevant 
	institutions as those medical research institutions that (01) appear in at 
	least three separate years of the cgaf data AND (02) received at least five
	grants over those years. Some additional institutions were added on a case-
	by-case basis. In total, there were 751 unique institutions. For those 751
	institutions, we have agreements for 576 institutions and we do not have 
	agreements for the remaining 175 institutions. 
	
	For those 576 institutions for which we have an agreement, we are interested
	in the "ON CAMPUS" or "ON SITE" rates pertaining to medical research. In 
	some cases, determing which rates are "ON SITE" or "ON CAMPUS" is not 
	obvious (e.g., "ATLANTA LAB" for Georgia Tech). For those observations, we 
	performed a manual confirmation that the rates were in fact those that we
	wished to keep. 
	
// -------------------------------- End Note -------------------------------- */

// ------- create "relevant" subset of data ------- //

	// ----- get the relevant institutions ----- //
	import delimited "${byhand}/relevant_subset.csv", varnames(1) clear
	trim_subroutine
	duplicates drop
	
	// ----- merge to subset nicra panel data ----- //
	merge 1:m institution using "${nih_output}/nicra_panel.dta"
	
	// ----- keep matched and unmatched relevant institutions ----- //
	drop if _merge == 2
	
	// ----- create a concordance of institutions ----- //
	/*  this concordance maps the original institution as scraped by the python
		script (or added via stata for those few where there were scraping 
		errors) to the final clean name used in nicra_panel. 
	*/
	preserve
	keep *institution
	duplicates drop
	rename institution final_institution
	replace original_institution = "RELEVANT INSTITUTION NOT IN AGREEMENTS" if missing(original_institution)
	order final_institution post_subinstitution original_institution
	sort final_institution post_subinstitution original_institution
	trim_subroutine
	export delimited "${nih_output}/relevant_institution_concordance.csv", replace
	restore
	
	// ----- keep only matched institutions (we'll add others back later) ----- //
	keep if _merge == 3
	drop original_institution post_subinstitution _merge
	// ----- keep observations of interest ----- //
	
	keep if inlist(location, "-", "ALL LOCATIONS", "ATLANTA LAB", "AVERA RESEARCH INSTITUTE", "CANCER CENTER") | ///
		inlist(location, "MAIN CAMPUS", "MEDICAL CENTER", "MEDICAL SCHOOL", "MEDICAL SCHOOL AND AFFILIATED HOSPITAL", "ON CAMPUS") | ///
		inlist(location, "ON SITE", "PUBLIC HEALTH INSTITUTE", "SAN DIEGO BRANCH", "AFFILIATED HOSPITAL", "DOWNTOWN DENVER CAMPUS") | ///
		inlist(location, "EAST COAST", "HEALTH SCIENCES CAMPUS", "HOSP & ABEI", "HOSPITAL", "KANSAS UNIVERSITY MEDICAL CENTER RESEARCH INSTITUTE") | ///
		inlist(location, "LAKE UNION CAMPUS", "MOFFETT CENTER", "ON CAMPUS MODIFIED", "RESEARCH CORPORATION OF THE UNIVERSITY OF HAWAII") | ///
		inlist(location, "SCHOOL OF PUBLIC HEALTH", "SOUTHERN CALIFORNIA REGION", "BRUCE LYON RESEARCH LAB AND MARTIN LUTHER KING JR. PLAZA")
	
	keep if inlist(applicable, "-", "ALL ACTIVITIES", "ALL CAMPUSES", "ALL OTHER RESEARCH", "ALL PROGRAMS", "ALL SPONSORED ACTIVITIES") | ///
		inlist(applicable, "ALL SPONSORED PROGRAMS", "BASIC RESEARCH", "ENDOWED RESEARCH", "ORGANIZED RESEARCH", "ORGANIZED RESEARCH & INSTRUCTION", "OTHER SPONSORED RESEARCH", "RESEARCH") | ///
		inlist(applicable, "RESEARCH & AGRICULTURAL EXPERIMENTATION STATION", "RESEARCH & GENERAL CLINICAL RESEARCH CENTER", "RESEARCH & INSTRUCTION", "RESEARCH & REGIONAL MEDICAL PROGRAM", "RESEARCH & TRAINING", "RESEARCH - MAIN") | ///
		inlist(applicable, "RESEARCH - MEDICINE", "RESEARCH AND REGIONAL MEDICAL PROGRAM", "RESEARCH DIVISION", "SPONSORED RESEARCH", "SPONSORED PROJECTS") 

	// ----- drop observations not of interest ----- //
	#delimit ;
	local droplist
		`"
	"AGRICULTURE"
	"AGRICULTURE EXPERIMENT STATION"
	"AMERICAN RUSSIAN CENTER"
	"ARCTIC REGION SUPERCOMPUTING CENTER"
	"ARSC"
	"COLLEGE OF AGRICULTURE"
	"COLUMBIA CAMPUS, EXCLUDING THE SCHOOL OF MEDICINE"
	"DIVISION OF AGRICULTURE AND NATURAL RESOURCES"
	"DIVISION OF AGRICULTURE AND NATURAL RESOURCES, AWARDS PRIOR TO JULY 1, 1992"
	"DOD CONTRACTS AFTER 30 NOVEMBER 1993"
	"DOD CONTRACTS ONLY"
	"EXCLUDES MEDICAL CENTER"
	"EXCLUDES MEDICAL CENTER & SCHOOL OF AGRICULTURE"
	"EXCLUDING MEDICAL CENTER"
	"FRINGE (CASUAL OT)"
	"FRINGE (CASUAL)"
	"FRINGE (REG OT)"
	"FRINGE (REG)"
	"G&A"
	"LAMONT-DOHERTY EARTH OBSERVATORY"	
	"LDEO"		
	"NON-MEDICAL CENTER"
	"PHYSICAL SCIENCE LAB"
	"POKER FLAT"
	"SCHOOL OF AGRICULTURE"
	"SCHOOL OF DENTISTRY" 
	"SCHOOL OF EDUCATION" 
	"SHIP OPERATIONS"
	"SPACE SCIENCE LAB"
	"SPECIAL PURPOSE RESEARCH SEGMENT."
	"';
	#delimit cr
	
	foreach element of local droplist {
		drop if special_remark == "`element'"
	}

	// ----- specific drops ----- //
	drop if institution == "CASE WESTERN RESERVE UNIVERSITY" & filename == "U6511006.TXT" & special_remark == "" 
	// we're keeping the College of Medicine Rates, not the rest 

	drop if institution == "YALE UNIVERSITY" & location == "ON CAMPUS MODIFIED"
	// modified rates are more restrictive 
	
	drop if institution == "UNIVERSITY OF ALASKA AT ANCHORAGE" & special_remark == "OTHER SPONSORED ACTIVITIES"
	// we have on campus research rates 
	
	drop if institution == "HARVARD UNIVERSITY SCHOOL OF PUBLIC HEALTH" & location == "ON CAMPUS" 
	// original entry was "Univ Area". We want actual public health research

	// ----- simplify location entries ----- //
	replace location = "ON CAMPUS" if location == "-"
	replace location = "ON CAMPUS" if location == "AFFILIATED HOSPITAL"
	replace location = "ON CAMPUS" if location == "DOWNTOWN DENVER CAMPUS"
	replace location = "ON CAMPUS" if location == "EAST COAST"
	replace location = "ON CAMPUS" if location == "HEALTH SCIENCES CAMPUS"
	replace location = "ON CAMPUS" if location == "HOSP & ABEI"
	replace location = "ON CAMPUS" if location == "KANSAS UNIVERSITY MEDICAL CENTER RESEARCH INSTITUTE"
	replace location = "ON CAMPUS" if location == "LAKE UNION CAMPUS"
	replace location = "ON CAMPUS" if location == "MAIN CAMPUS"
	replace location = "ON CAMPUS" if location == "MEDICAL SCHOOL"
	replace location = "ON CAMPUS" if location == "MEDICAL SCHOOL AND AFFILIATED HOSPITAL"
	replace location = "ON CAMPUS" if location == "MOFFETT CENTER"
	replace location = "ON CAMPUS" if location == "ON CAMPUS MODIFIED"
	replace location = "ON CAMPUS" if location == "ON SITE"
	replace location = "ON CAMPUS" if location == "PUBLIC HEALTH INSTITUTE"
	replace location = "ON CAMPUS" if location == "SAN DIEGO BRANCH"
	replace location = "ON CAMPUS" if location == "SCHOOL OF PUBLIC HEALTH"
	replace location = "ON CAMPUS" if location == "SOUTHERN CALIFORNIA REGION"

	// ----- simplify applicable entries ----- //
	replace applicable = "ALL PROGRAMS" if applicable == "-"
	replace applicable = "ALL PROGRAMS" if applicable == "ALL CAMPUSES"
	replace applicable = "ALL PROGRAMS" if applicable == "ALL SPONSORED ACTIVITIES"
	replace applicable = "ALL PROGRAMS" if applicable == "ALL SPONSORED PROGRAMS"
	replace applicable = "ALL PROGRAMS" if applicable == "SPONSORED PROJECTS"
	replace applicable = "RESEARCH" if applicable == "ALL OTHER RESEARCH"
	replace applicable = "RESEARCH" if applicable == "BASIC RESEARCH"
	replace applicable = "RESEARCH" if applicable == "ENDOWED RESEARCH"
	replace applicable = "RESEARCH" if applicable == "ORGANIZED RESEARCH"
	replace applicable = "RESEARCH" if applicable == "ORGANIZED RESEARCH & INSTRUCTION"
	replace applicable = "RESEARCH" if applicable == "OTHER SPONSORED RESEARCH"
	replace applicable = "RESEARCH" if applicable == "RESEARCH & AGRICULTURAL EXPERIMENTATION STATION"
	replace applicable = "RESEARCH" if applicable == "RESEARCH & GENERAL CLINICAL RESEARCH CENTER"
	replace applicable = "RESEARCH" if applicable == "RESEARCH & INSTRUCTION"
	replace applicable = "RESEARCH" if applicable == "RESEARCH & REGIONAL MEDICAL PROGRAM"
	replace applicable = "RESEARCH" if applicable == "RESEARCH & TRAINING"
	replace applicable = "RESEARCH" if applicable == "RESEARCH - MAIN"
	replace applicable = "RESEARCH" if applicable == "RESEARCH - MEDICINE"
	replace applicable = "RESEARCH" if applicable == "RESEARCH AND REGIONAL MEDICAL PROGRAM"
	replace applicable = "RESEARCH" if applicable == "RESEARCH DIVISION"
	replace applicable = "RESEARCH" if applicable == "SPONSORED RESEARCH"

	// ----- save ----- //
	trim_subroutine
	save "${nih_output}/nicra_panel.dta", replace
	clear
	
/* ------------------------------- Begin Note ------------------------------- // 

	Operation 04: Reshape the data  
	
	Unfortunately, the code for this section is not easy to follow. Broadly, 
	each agreement covers somewhere between one to five years with each rate 
	within an agreement covering between three months to five years. To further
	complicate things, agreements and the individual rates therein start at 
	different times and sometimes overlap (i.e., a more recent agreement may 
	supercede the previous agreeemnt). Because we require a dateset where each 
	observation is comparable, we chose to reshape the data so that each row 
	represents a unique institution-year-month grouping. When overlaps occur 
	between agreements, we keep the most recent agreement for the timeframe of 
	the overlap. 
	
	We perform this reshaping in three steps: 
	
	1.	We break each effective_from-effective_to pairs into at most one year 
		spans. This makes it easier to break the spans into months. 
	2.	We expand each of the one year spans into months to arrive at the 
		institution-year-month grouping.
	3.	We remove the overlapped observations. That is, when there are two 
		duplicated institution-year-month groupings, we keep the group from the
		most recent agreement (using agreement_date). 
	
// -------------------------------- End Note -------------------------------- */

// ------- 	Reshape the data to panel form ------- //
	
	// ----- drop "UNTIL AMENDED" rates ----- //
	
		// --- data --- //
		use  "${nih_output}/nicra_panel.dta", clear
		drop if missing(effective_to) | strpos(rate, "USE SAME")

		// --- save --- //
		trim_subroutine
		tempfile nicra_panel
		save `nicra_panel', replace
		clear		
	

/*  We have two options here: (a) assume some amount of time for those rates 
	listed as "Until Amended" or (b) drop those rates. We have chosen to drop 
	those, which we consider the more conservative option. But we have left the
	code for assuming a one year extension before amendment if one wishes to 
	explore the alternative. Remember to comment out the code above that drops
	the Until Amended observations. 

	// ----- allow one year for until amended rates ----- //
	
		// --- data --- //
		use  "${nih_output}/nicra_panel.dta", clear

		// --- flag observations where we assume an until amended date --- //
		gen until_amended = "NO"
		replace until_amended = "YES" if missing(effective_to)
		
		// --- add one year for until amended --- //
		replace effective_to = effective_from + 365 if missing(effective_to)
		sort filename inst effective_from effective_to		

		// --- use same rates for until amended adjustment (where noted in the agreement) --- //
		replace rate = rate[_n-1] if strpos(rate, "USE SAME RATES") & institution == institution[_n-1] & filename == filename[_n-1]
		drop if strpos(rate, "USE SAME RATES")
		
		// --- save --- //
		trim_subroutine
		tempfile nicra_panel
		save `nicra_panel', replace
		clear
		
*/		

	// ----- add all relevant institution without agreements ----- // 
	import delimited using "${byhand}/relevant_subset.csv", varnames(1) clear
	trim_subroutine
	merge 1:m institution using `nicra_panel'
	drop if _merge == 2
		
	// ----- add dates for relevant institutions not in foia1 ----- //
	// this keeps these institutions from being dropped in the process
	replace effective_from = date("01/01/1980", "MDY", 2015) if _merge == 1
	replace effective_to = date("12/31/2010", "MDY", 2015) if _merge == 1
	replace location = "-" if missing(location)
	replace applicable = "-" if missing(applicable)
	drop _merge
	
	// ----- determine # years spanned by each observation ----- //
	gen num_years = year(effective_to) - year(effective_from)
	levelsof num_years
	local year_levels = r(levels)
	
	tempfile foia_working
	save `foia_working', replace
		
	local obs = _N
	drop in 1/`obs'
	
	// ---- group observations by year span ----- //
	foreach level of local year_levels {
		tempfile year`level'
		save `year`level'', replace
	}

	// ----- expand each level to one year maximum span ----- //
		foreach level of local year_levels {
			
			// --- data --- //
			use `foia_working', clear
			keep if num_years == `level' 
			
			// --- simple (i.e., start and end year are the same already) --- //
			if `level' == 0 {
				drop num_years
				sort institution agreement_date rate_type effective_from effective_to rate location applicable 
				save `year`level'', replace
			}
			
			// --- complex (i.e., more than one year spanned by at least one month) --- //
			if `level' > 0 {

				// - expand - // 
				expand `level'
			
				// - increment years (i.e., count up the years) - //
				bysort  institution agreement_date rate_type effective_from effective_to rate location applicable ///
					 filename: gen year = year(effective_from) + _n
				
					// - error check (ensure max year expanded to does not exceed max year of the agreement) - //
					gen maxyear = year(effective_to)
					count if maxyear < year
					if r(N) != 0 {
						display as error "incorrect year assignments when reshaping to panel data"
						display as error "some observations being assigned a year greater than the maximum for that agreement"
						display as error "to see incorrect observations: keep if maxyear < year"
						display as error "no simple solution available, must correct code"
						exit 1
					}
					drop maxyear
				
				// --- separate dates into day, month, year componenets --- //			
				gen from_day = day(effective_from)
				gen from_month = month(effective_from)
				gen from_year = year(effective_from)
				gen to_day = day(effective_to)
				gen to_month = month(effective_to)
				gen to_year = year(effective_to)		

				// --- replace year with incremented year from above --- //
				replace to_year = year
				replace from_year = year - 1
				
				// --- replace old effective dates with new --- //
				tostring from*, replace
				tostring to*, replace
								
				gen effective_from_new = from_day + "/" + from_month  + "/" + from_year
				gen effective_to_new = to_day  + "/" + to_month + "/" + to_year
				replace effective_from = date(effective_from_new, "DMY", 2015)
				replace effective_to = date(effective_to_new, "DMY", 2015)
				format effective_from %td
				format effective_to %td		
				
				drop from* to* *_new year
				
				// - unusual timeframes - //
				gen days = (effective_to - effective_from) + 1
				
					// - expand - //
					sort  institution agreement_date location applicable effective_from effective_to
					by institution agreement_date location applicable: gen expand_id = _n
					by institution agreement_date location applicable: egen max_id = max(expand_id)
					replace expand_id = 0 if days <= 375
					expand 2 if expand_id == max_id
					drop *id
					
					// - adjust dates - //
					sort  institution agreement_date location applicable effective_from effective_to
					by institution agreement_date location applicable: gen adjust_id = _n
					by institution agreement_date location applicable: egen max_id = max(adjust_id)					
					
						// + Standard Year + //
						replace effective_to = effective_from + 364 if days > 375 & adjust_id < max_id
						replace effective_from = effective_to[_n-1] + 1 if days > 375 & adjust_id == max_id
					
						// + Leap Years + //
						replace effective_to = effective_to + 1 if days > 375 & year(effective_to)/4 == int(year(effective_to)/4)
						replace effective_to = effective_to - 1 if days > 375 & day(effective_to) == 1	
						replace effective_from = effective_from + 1 if days > 375 & effective_from == effective_to[_n -1]
						
				drop num_years days *id
				
				// - save - //
				sort  institution agreement_date rate_type effective_from effective_to rate location applicable 				
				save `year`level'', replace
				
			}
		}
			
	// ----- append all expanded to year timeframe observations ----- //
	use `foia_working', clear
	keep in 1
	drop in 1
	drop num_years
		
	foreach level of local year_levels {
		append using `year`level''
	}
	
	// ----- expand to month year pairs ----- //
	
		// --- generate --- //
		gen month_from = month(effective_from)
		gen year_from = year(effective_from)
		gen month_to = month(effective_to)
		gen year_to = year(effective_to)
		
		gen year_diff = year_to - year_from
	
		// --- create temporary files --- //
		preserve
		keep if year_diff == 0
		save "${nih_output}/year_zero.dta", replace
		restore
		drop if year_diff == 0
		tempfile year_one
		save "${nih_output}/year_one.dta", replace
		clear
		
		// --- same year (i.e., starts and ends in same calendar year) --- //
			
			// - data - //
			use "${nih_output}/year_zero.dta", clear
			
			gen month_diff = month_to - month_from
			
			// - dayratio (i.e., find number of months - //
			gen day_ratio = (effective_to - effective_from)/31
			replace month_diff = month_diff + 1 if day_ratio >= month_diff
			drop day_ratio
			
			// - get levels for expansion - //
			levelsof month_diff
			local month_levels = r(levels) 
			
			// - save - //
			save "${nih_output}/year_zero.dta", replace
			
			// - separate by month levels - //
			local obs = _N
			drop in 1/`obs'
			
			foreach level of local month_levels {
				save "${nih_output}/year_zero`level'.dta", replace
			}
			
			// - expand by month levels - //
			foreach level of local month_levels {
				
				// + data + //
				use "${nih_output}/year_zero.dta", clear
				keep if month_diff == `level'
				expand `level'
				
				// + increment months (i.e., add month one at a time) + //
				bysort  institution agreement_date rate_type effective_from effective_to rate location applicable ///
					 filename: gen month = month(effective_from) + _n -1
			
					// +++ error check (ensure max month doesn't excede the max for the observations) +++ //
					gen maxmonth = month(effective_to)
					count if month > maxmonth
					if r(N) != 0 {
						display as error "incorrect month assignment when reshaping panel data" 
						display as error "some observations assigned month greater than the max allowable"
						display as error "to see incorrect observations: keep if monthtest > month_diff"
						display as error "no simple solution available; must correct code" 
						display as error "error generated in programme panel_formatting"
						exit 1
					}
					
					drop maxmonth

				// + finalise + //
				gen year = year_from
				drop month_from month_to year_from year_to month_diff year_diff
				rename effective_from original_from
				rename effective_to original_to
				
				// + save + //
				order institution city state zip_code agreement_date rate_type month year rate location applicable agency ///
					director representative telephone filename special_remark 
				sort  institution agreement_date year month
				save "${nih_output}/year_zero`level'", replace
				
				// + clear + //
				clear
			}

		// --- one year (i.e., observation spans to next calendar year)--- //
			
			// - data - //
			use "${nih_output}/year_one.dta", clear
			duplicates drop
			gen month_diff = month_from - month_to
			replace month_diff = 13 - month_diff 
						
			levelsof month_diff
			local month_levels = r(levels)
			
			// - save - //
			save "${nih_output}/year_one.dta", replace
			
			// - default - //
			local obs = _N
			drop in 1/`obs'
			
			foreach level of local month_levels {
				tempfile year_one`level'
				save "${nih_output}/year_one`level'.dta", replace
			}
					
			// - levels - //
			foreach level of local month_levels {

				// + data + //
					use "${nih_output}/year_one.dta", clear
					keep if month_diff == `level'
					expand `level'			

				// + increment months + //
				bysort institution agreement_date rate_type effective_from effective_to rate location applicable ///
					 filename: gen month = month(effective_from) + _n -1				
				
				// + turn of year (adjust month numbers when year ticks over to next year+ //
				gen year = year_from
				replace year = year + 1 if month > 12
				replace month = month - 12 if month > 12
				
					// +++ error check (enusure no obvious errors in max year) +++ //
					gen maxyear = year(effective_to)
					count if maxyear < year
					if r(N) != 0 {
						display as error "incorrect year assignments when reshaping month panel data"
						display as error "some observations being assigned a year greater than the maximum"
						display as error "to see incorrect observations: keep if maxyear < year"
						display as error "no simple solution available, must correct code or input files"
						exit 1
					}
					
					drop maxyear

				// + finalise + //
				drop month_from month_to year_from year_to month_diff year_diff
				rename effective_from original_from
				rename effective_to original_to
					
				// + save + //
				order institution city state zip_code agreement_date rate_type month year rate location applicable agency ///
					director representative telephone filename special_remark 
				sort  institution agreement_date year month
				save "${nih_output}/year_one`level'.dta", replace
					
				// + clear + //
				clear
			}			

		// --- append temporary files to rebuild nicra_panel--- //
		use "${nih_output}/year_zero1.dta", clear
		local obs = _N
		drop in 1/`obs'
		save "${nih_output}/nicra_panel.dta", replace
		clear
		
		filelist, directory("$nih_output") pattern("*.dta")
		drop if inlist(filename, "year_one.dta", "year_zero.dta", "nicra_panel.dta")
	
		local obs = _N
		forval x = 1/`obs' {
			
			// - preserve - //
			preserve
		
			// - locals - //
			local appendfile = filename[`x']
			
			// - append - //
			use "${nih_output}/`appendfile'", clear
			append using "${nih_output}/nicra_panel.dta"
			
			// - save - //
			save "${nih_output}/nicra_panel.dta", replace
			clear
			
			// - remove - //
			rm "${nih_output}/`appendfile'"
			
			// - restore - //
			restore

		}
			
	// ----- remove unnecessary data files ----- //
	rm "${nih_output}/year_zero.dta"
	rm "${nih_output}/year_one.dta"
	
	// ----- destring rate ----- //
	use "${nih_output}/nicra_panel.dta", clear
	drop if rate == "USE SAME RATES - NOT UNTIL AMENDED"
	destring rate, generate(rate1)
	drop rate

// ------- handle overlapping agreement observations ------- //

	sort  institution year month agreement_date
	forval x = 1/2 { 
		drop if institution == institution[_n+1] & month == month[_n+1] & year == year[_n+1] & agreement_date <= agreement_date[_n+1]
	}

	// ----- save ----- //
	trim_subroutine
	order institution city state zip_code agreement_date rate_type month year rate1 location applicable agency ///
		director representative telephone filename special_remark 
	sort  institution agreement_date year month	
	save "${nih_output}/nicra_panel.dta", replace
	clear

/* ------------------------------- Begin Note ------------------------------- // 

	Operation 05: Add foia2 rates. 
	
	Please note: Large code blocks have been commented out in case we choose to 
	revisit our decisions regarding which foia2 rate to use. These blocks 
	contain the code to match foia2 rates to foia1 rates starting in July of a 
	given year to June of the following year, which provides the most matches.

	
// -------------------------------- End Note -------------------------------- */

// ------- foia 2 ------- //

	// ----- get foia2 data ----- //
	import delimited using "${hhs}/foia2_long.csv", varnames(1) clear stringcols(_all)
	trim_subroutine
	
	destring rate, replace
	destring year, replace
	
	// ----- create for foia2 concordance ----- //
	gen original_institution = foia2_institution
		
	// ----- standard foia2_institution names ----- //
	replace foia2_institution = "ALABAMA AGRICULTURAL AND MECHANICAL UNIVERSITY" if foia2_institution == "ALABAMA A&M UNIVERSITY"
	replace foia2_institution = "ALABAMA AGRICULTURE AND MECHANICAL UNIVERSITY - SCHOOL OF AGRICULTURE" if foia2_institution == "ALABAMA A&M UNIVERSITY - SCH OF AGRICULTURE"
	replace foia2_institution = "AUBURN UNIVERSITY AT AUBURN" if foia2_institution == "AUBURN UNIVERSITY"
	replace foia2_institution = "CALIFORNIA STATE POLYTECHNIC UNIVERSITY AT POMONA" if foia2_institution == "CAL POLY POMONA FOUNDATION, INC."
	replace foia2_institution = "CALIFORNIA STATE UNIVERSITY AT FULLERTON" if foia2_institution == "CSU FULLERTON"
	replace foia2_institution = "CALIFORNIA STATE UNIVERSITY AT LONG BEACH" if foia2_institution == "CAL STATE LONG BEACH & THE FOUNDATION"
	replace foia2_institution = "CALIFORNIA STATE UNIVERSITY AT LOS ANGELES" if foia2_institution == "CAL STATE L.A. UNIVERSITY AUXILIARY SERVICES, INC."
	replace foia2_institution = "CHARLES R. DREW UNIVERSITY OF MEDICINE AND SCIENCE" if foia2_institution == "CHARLES DREW UNIVERSITY OF MEDICAL & SCIENCE"
	replace foia2_institution = "COLORADO STATE UNIVERSITY AT FORT COLLINS" if foia2_institution == "COLORADO STATE UNIVERSITY"
	replace foia2_institution = "COLUMBIA UNIVERSITY IN THE CITY OF NEW YORK" if foia2_institution == "COLUMBIA UNIVERSITY"
	replace foia2_institution = "CORNELL UNIVERSITY - CONTRACT COLLEGES" if foia2_institution == "CORNELL UNIVERSITY - CONTR. COLL."
	replace foia2_institution = "CORNELL UNIVERSITY" if foia2_institution == "CORNELL UNIVERSITY -ENDOWED"
	replace foia2_institution = "CUNY - BROOKLYN COLLEGE" if foia2_institution == "RFCUNY- BROOKLYN COLLEGE"
	replace foia2_institution = "CUNY - CITY COLLEGE" if foia2_institution == "RFCUNY - CITY COLLEGE"
	replace foia2_institution = "CUNY - GRADUATE CENTER" if foia2_institution == "RFCUNY - GRADUATE CENTER"
	replace foia2_institution = "CUNY - HUNTER COLLEGE" if foia2_institution == "RFCUNY-HUNTER COLLEGE"
	replace foia2_institution = "CUNY - QUEENS COLLEGE" if foia2_institution == "RFCUNY-QUEENS COLLEGE"
	replace foia2_institution = "DE PAUL UNIVERSITY" if foia2_institution == "DEPAUL UNIVERSITY"
	replace foia2_institution = "FLORIDA AGRICULTURAL AND MECHANICAL UNIVERSITY" if foia2_institution == "FLORIDA AGRICULTURAL & MECHANICAL UNIVERSITY"
	replace foia2_institution = "GEORGE WASHINGTON UNIVERSITY MEDICAL CENTER" if foia2_institution == "GEORGE WASHINGTON UNV. MEDICAL CENTER"
	replace foia2_institution = "HARVARD MEDICAL SCHOOL" if foia2_institution == "HARVARD MEDICAL SCHOOL."
	replace foia2_institution = "HARVARD UNIVERSITY SCHOOL OF PUBLIC HEALTH" if foia2_institution == "HARVARD SCHOOL OF PUBLIC HEALTH"
	replace foia2_institution = "KENT STATE UNIVERSITY AT KENT" if foia2_institution == "KENT STATE UNIVERSITY"
	replace foia2_institution = "LOUISIANA STATE UNIVERSITY AGRICULTURAL AND MECHANICAL COLLEGE AT BATON ROUGE" if foia2_institution == "LOUISIANA STATE UNIVERSITY"
	replace foia2_institution = "LOUISIANA STATE UNIVERSITY HEALTH SCIENCES CENTER AT NEW ORLEANS" if foia2_institution == "LOUISIANA STATE UNIVERSITY HEALTH SCIENCES CENTER, NEW ORLEANS"
	replace foia2_institution = "LOUISIANA STATE UNIVERSITY HEALTH SCIENCES CENTER AT SHREVEPORT" if foia2_institution == "LOUISIANA STATE UNIVERSITY HEALTH SCIENCES CENTER, SHREVEPORT"
	replace foia2_institution = "LOYOLA UNIVERSITY MEDICAL CENTER" if foia2_institution == "LOYOLA UNIVERSITY OF CHICAGO (MAYWOOD)"
	replace foia2_institution = "LOYOLA UNIVERSITY OF CHICAGO" if foia2_institution == "LOYOLA UNIVERSITY OF CHICAGO (LAKESIDE)"
	replace foia2_institution = "MONTANA STATE UNIVERSITY AT BOZEMAN" if foia2_institution == "MONTANA STATE UNIVERSITY"
	replace foia2_institution = "MOUNT SINAI SCHOOL OF MEDICINE" if foia2_institution == "MT SINAI SCHOOL OF MEDICINE"
	replace foia2_institution = "NEW JERSEY INSTITUTE OF TECHNOLOGY" if foia2_institution == "NEW JERSEY INSTITUTE OF TECH."
	replace foia2_institution = "NEW MEXICO HIGHLANDS UNIVERSITY" if foia2_institution == "NEW MEXICO, HIGHLANDS UNIVERSITY"
	replace foia2_institution = "NEW YORK UNIVERSITY MEDICAL CENTER" if foia2_institution == "NEW YORK UNIV MEDICAL SCHOOL"
	replace foia2_institution = "NORTH CAROLINA STATE UNIVERSITY AT RALEIGH" if foia2_institution == "NORTH CAROLINA STATE UNIVERSITY"
	replace foia2_institution = "OHIO STATE UNIVERSITY" if foia2_institution == "OHIO STATE UNIVERSITY RESEARCH FOUNDATION"
	replace foia2_institution = "OHIO UNIVERSITY AT ATHENS" if foia2_institution == "OHIO UNIVERSITY"
	replace foia2_institution = "OREGON HEALTH AND SCIENCE UNIVERSITY" if foia2_institution == "OREGON HEALTH & SCIENCE UNIVERSITY"
	replace foia2_institution = "PRAIRIE VIEW AGRICULTURAL AND MECHANICAL UNIVERSITY" if foia2_institution == "PRAIRIE VIEW A&M UNIVERSITY"
	replace foia2_institution = "PURDUE UNIVERSITY AT WEST LAFAYETTE" if foia2_institution == "PURDUE UNIVERSITY"
	replace foia2_institution = "ROCHESTER INSTITUTE OF TECHNOLOGY" if foia2_institution == "ROCHESTER INSTITUTE OF TECH."
	replace foia2_institution = "ROSENSTIEL SCHOOL OF MARINE AND ATMOSPHERIC SCIENCE" if foia2_institution == "MIAMI: MARINE CAMPUS, UNIVERSITY OF"
	replace foia2_institution = "RUTGERS UNIVERSITY AT NEW BRUNSWICK" if foia2_institution == "RUTGERS - STATE U OF NEW JERSEY"
	replace foia2_institution = "SAINT LOUIS UNIVERSITY" if foia2_institution == "ST. LOUIS UNLVERSITY"
	replace foia2_institution = "SAN DIEGO STATE UNIVERSITY" if foia2_institution == "SAN DIEGO STATE UNIVERSITY RESEARCH FOUNDATION"
	replace foia2_institution = "STATE UNIVERSITY OF NEW YORK" if foia2_institution == "RFSUNY - CENTRAL ADMIN."
	replace foia2_institution = "SUNY - BUFFALO STATE COLLEGE" if foia2_institution == "RFSUNY - BUFFALO"
	replace foia2_institution = "SUNY - COLLEGE OF ENVIRONMENTAL SCIENCE AND FORESTRY" if foia2_institution == "RFSUNY - COLLEGE OF ENVIRON SCI"
	replace foia2_institution = "SUNY - DOWNSTATE MEDICAL CENTER" if foia2_institution == "RFSUNY - HLTH SCI CTR - BKLYN"
	replace foia2_institution = "SUNY - STATE UNIVERSITY OF NEW YORK AT ALBANY" if foia2_institution == "RFSUNY-ALBANY"
	replace foia2_institution = "SUNY - STATE UNIVERSITY OF NEW YORK AT BINGHAMTON" if foia2_institution == "RFSUNY - BINGHAMTON"
	replace foia2_institution = "SUNY - STATE UNIVERSITY OF NEW YORK AT BUFFALO" if foia2_institution == "RFSUNY - COLLEGE OF BUFFALO"
	replace foia2_institution = "SUNY - STATE UNIVERSITY OF NEW YORK AT STONYBROOK" if foia2_institution == "RESUNY - STONYBROOK"
	replace foia2_institution = "SUNY - UPSTATE MEDICAL UNIVERSITY" if foia2_institution == "RFSUNY - UPSTATE MEDICAL UNIVERSITY"
	replace foia2_institution = "TEXAS AGRICULTURAL AND MECHANICAL UNIVERSITY AT COLLEGE STATION" if foia2_institution == "TEXAS A&M"
	replace foia2_institution = "TEXAS TECH UNIVERSITY HEALTH SCIENCES CENTER" if foia2_institution == "TEXAS TECH UNIVERSITY MSC"
	replace foia2_institution = "TUFTS-NEW ENGLAND MEDICAL CENTER" if foia2_institution == "TUFTS UNIVERSITY-HEALTH SCIENCES"
	replace foia2_institution = "TUFTS UNIVERSITY - MEDFORD" if foia2_institution == "TUFTS UNIVERSITY-MEDFORD/SOMERVILLE"
	replace foia2_institution = "TUSKEGEE UNIVERSITY" if foia2_institution == "TUSKEGGE UNIVERSITY"
	replace foia2_institution = "UNIVERSITY OF AKRON" if foia2_institution == "AKRON, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF ALABAMA AT BIRMINGHAM" if foia2_institution == "ALABAMA - BIRMINGHAM, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF ALABAMA AT HUNTSVILLE" if foia2_institution == "ALABAMA: HUNTSVILLE, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF ALABAMA AT TUSCALOOSA" if foia2_institution == "ALABAMA: TUSCALOOSA, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF ARIZONA" if foia2_institution == "ARIZONA, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF ARKANSAS AT FAYETTEVILLE" if foia2_institution == "ARKANSAS, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF ARKANSAS AT LITTLE ROCK" if foia2_institution == "ARKANSAS AT LITTLE ROCK, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF ARKANSAS MEDICAL SCIENCES AT LITTLE ROCK" if foia2_institution == "ARKANSAS: FOR MEDICAL SCIENCES. UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF CALIFORNIA AT BERKELEY" if foia2_institution == "CALIFORNIA - BERKELEY, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF CALIFORNIA AT DAVIS" if foia2_institution == "CALIFORNIA - DAVIS, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF CALIFORNIA AT IRVINE" if foia2_institution == "CALIFORNIA - IRVINE, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF CALIFORNIA AT LOS ANGELES" if foia2_institution == "CALIFORNIA - LOS ANGELES, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF CALIFORNIA AT RIVERSIDE" if foia2_institution == "CALIFORNIA - RIVERSIDE, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF CALIFORNIA AT SAN DIEGO" if foia2_institution == "CALIFORNIA - SAN DIEGO, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF CALIFORNIA AT SAN FRANCISCO" if foia2_institution == "CALIFORNIA - SAN FRANCISCO, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF CALIFORNIA AT SANTA BARBARA" if foia2_institution == "CALIFORNIA - SANTA BARBARA, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF CALIFORNIA AT SANTA CRUZ" if foia2_institution == "CALIFORNIA - SANTA CRUZ, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF CENTRAL FLORIDA" if foia2_institution == "CENTRAL FLORIDA. UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF CHICAGO" if foia2_institution == "CHICAGO, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF CINCINNATI" if foia2_institution == "CINCINNATI, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF COLORADO AT BOULDER" if foia2_institution == "COLORADO AT BOULDER. UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF COLORADO DENVER HEALTH SCIENCES CENTER" if foia2_institution == "COLORADO AT DENVER, UNIVERSITY OF & HEALTH SCIENCE"
	replace foia2_institution = "UNIVERSITY OF CONNECTICUT AT STORRS" if foia2_institution == "UNIV OF CONNECTICUT"
	replace foia2_institution = "UNIVERSITY OF CONNECTICUT SCHOOL OF MEDICINE AND DENTISTRY" if foia2_institution == "UNIV OF CT HLTH SCIENCE CTR"
	replace foia2_institution = "UNIVERSITY OF FLORIDA" if foia2_institution == "FLORIDA, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF GEORGIA" if foia2_institution == "GEORGIA: RESEARCH FOUNDATION, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF HAWAII" if foia2_institution == "HAWAII, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF HOUSTON" if foia2_institution == "HOUSTON, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF IDAHO" if foia2_institution == "IDAHO, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF IOWA" if foia2_institution == "IOWA, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF KANSAS AT LAWRENCE" if foia2_institution == "KANSAS. UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF KANSAS MEDICAL CENTER" if foia2_institution == "KANSAS MEDICAL CENTER, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF KENTUCKY" if foia2_institution == "KENTUCKY, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF LOUISIANA AT LAFAYETTE" if foia2_institution == "UNIVERSITY OF LOUISIANA LAFAYETTE"
	replace foia2_institution = "UNIVERSITY OF LOUISVILLE" if foia2_institution == "LOUISVILLE, UNIVERSITY OF: RESEARCH FOUNDATION"
	replace foia2_institution = "UNIVERSITY OF MAINE" if foia2_institution == "UNIV OF MAINE"
	replace foia2_institution = "UNIVERSITY OF MARYLAND - CENTER FOR ENVIRONMENTAL AND ESTUARINE STUDIES" if foia2_institution == "MARYLAND CENTER FOR ENVIRONMENTAL SCIENCE, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF MARYLAND AT BALTIMORE COUNTY" if foia2_institution == "MARYLAND - BALTIMORE COUNTY, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF MARYLAND AT BALTIMORE" if foia2_institution == "MARYLAND @ BALTIMORE"
	replace foia2_institution = "UNIVERSITY OF MARYLAND AT COLLEGE PARK" if foia2_institution == "MARYLAND - COLLEGE PARK, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF MASSACHUSETTS - CENTRAL ADMINISTRATION" if foia2_institution == "UNIV MASS - CENTRAL ADMIN."
	replace foia2_institution = "UNIVERSITY OF MASSACHUSETTS AT AMHERST" if foia2_institution == "UNIV OF MASSACHUSETTTS - AMHERST"
	replace foia2_institution = "UNIVERSITY OF MASSACHUSETTS AT DARTMOUTH" if foia2_institution == "UNIV MASS - DARTMOUTH"
	replace foia2_institution = "UNIVERSITY OF MASSACHUSETTS AT LOWELL" if foia2_institution == "UNIV MASS - LOWELL CAMPUS"
	replace foia2_institution = "UNIVERSITY OF MASSACHUSETTS MEDICAL SCHOOL AT WORCESTER" if foia2_institution == "UNIV OF MASS - MEDICAL SCHOOL"
	replace foia2_institution = "UNIVERSITY OF MEDICINE AND DENTISTRY OF NEW JERSEY" if foia2_institution == "UNIV OF MED & DENT OF NJ"
	replace foia2_institution = "UNIVERSITY OF MEMPHIS" if foia2_institution == "MEMPHIS, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF MIAMI AT CORAL GABLES" if foia2_institution == "MIAMI: CORAL GABLES CAMPUS, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF MIAMI SCHOOL OF MEDICINE" if foia2_institution == "MIAMI: MEDICAL CAMPUS, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF MICHIGAN" if foia2_institution == "MICHIGAN, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF MINNESOTA AT TWIN CITIES" if foia2_institution == "MINNESOTA, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF MISSISSIPPI MEDICAL CENTER" if foia2_institution == "MISSISSIPPI: MEDICAL CENTER, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF MISSISSIPPI" if foia2_institution == "MISSISSIPPI, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF MISSOURI AT COLUMBIA" if foia2_institution == "MISSOURI - COLUMBIA, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF MISSOURI AT KANSAS CITY" if foia2_institution == "MISSOURI - KANSAS CITY, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF MISSOURI AT ROLLA" if foia2_institution == "MISSOURI UNIVERSITY OF SCIENCE AND TECHNOLOGY (ROLLA)"
	replace foia2_institution = "UNIVERSITY OF MISSOURI AT ST. LOUIS" if foia2_institution == "MISSOURI - ST LOUIS. UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF MONTANA" if foia2_institution == "MONTANA, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF NEBRASKA AT LINCOLN" if foia2_institution == "NEBRASKA - LINCOLN, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF NEBRASKA MEDICAL CENTER" if foia2_institution == "NEBRASKA MEDICAL CENTER, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF NEVADA AT LAS VEGAS" if foia2_institution == "NEVADA- LAS VEGAS, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF NEVADA AT RENO" if foia2_institution == "NEVADA - RENO. UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF NEW HAMPSHIRE" if foia2_institution == "UNIV OF NEW HAMPSHIRE"
	replace foia2_institution = "UNIVERSITY OF NEW MEXICO AT ALBUQUERQUE" if foia2_institution == "NEW MEXICO, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF NORTH CAROLINA AT CHAPEL HILL" if foia2_institution == "NORTH CAROLINA - CHAPEL HILL, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF NORTH CAROLINA AT WILMINGTON" if foia2_institution == "NORTH CAROLINA AT WILMINGTON, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF NORTH DAKOTA" if foia2_institution == "NORTH DAKOTA, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF NORTH FLORIDA" if foia2_institution == "NORTH FLORIDA. UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF NORTH TEXAS HEALTH SCIENCE CENTER" if foia2_institution == "NORTH TEXAS HSC FT. WORTH. UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF NORTH TEXAS" if foia2_institution == "NORTH TEXAS, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF NOTRE DAME DU LAC" if foia2_institution == "NOTRE DAME, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF OKLAHOMA AT NORMAN" if foia2_institution == "OKLAHOMA, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF OKLAHOMA HEALTH SCIENCES CENTER" if foia2_institution == "OKLAHOMA HEALTH SCIENCES CENTER, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF OREGON AT EUGENE" if foia2_institution == "OREGON - EUGENE, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF PITTSBURGH AT PITTSBURGH" if foia2_institution == "PITTSBURGH, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF PUERTO RICO AT MAYAGUEZ" if foia2_institution == "UNIV OF PUERTO RICO - MAYAGUEZ"
	replace foia2_institution = "UNIVERSITY OF PUERTO RICO AT RIO PIEDRAS" if foia2_institution == "UNIV OF PUERTO RICO"
	replace foia2_institution = "UNIVERSITY OF PUERTO RICO MEDICAL SCIENCES" if foia2_institution == "UNIV OF PUERTO RICO - MEDICAL SCIENCES"
	replace foia2_institution = "UNIVERSITY OF SOUTH ALABAMA" if foia2_institution == "SOUTH ALABAMA, UNIVERSITY OF -SCH OF MEDICINE"
	replace foia2_institution = "UNIVERSITY OF SOUTH ALABAMA (NON-MEDICINE)" if foia2_institution == "SOUTH ALABAMA. UNIVERSITY OF - ALL OTHER SCHOOLS"
	replace foia2_institution = "UNIVERSITY OF SOUTH CAROLINA - SENIORS REGIONAL CAMPUSES" if foia2_institution == "SOUTH CAROLINA: SENIORS REGIONAL CAMPUSES, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF SOUTH CAROLINA AT COLUMBIA" if foia2_institution == "SOUTH CAROLINA, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF SOUTH CAROLINA SCHOOL OF MEDICINE" if foia2_institution == "SOUTH CAROLINA: SCHOOL OF MEDICINE, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF SOUTH DAKOTA" if foia2_institution == "SOUTH DAKOTA, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF SOUTH FLORIDA" if foia2_institution == "SOUTH FLORIDA, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF SOUTHERN CALIFORNIA" if foia2_institution == "SOUTHERN CALIFORNIA, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF SOUTHERN MISSISSIPPI" if foia2_institution == "MISSISSIPPI, UNIVERSITY OF SOUTHERN"
	replace foia2_institution = "UNIVERSITY OF TENNESSEE AGRICULTURAL EXPERIMENT STATION" if foia2_institution == "TENNESSEE: AGRICULTURAL EXPERIMENT STATION, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF TENNESSEE AT KNOXVILLE" if foia2_institution == "TENNESSEE: KNOXVILLE, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF TENNESSEE COLLEGE OF VETERINARY MEDICINE" if foia2_institution == "TENNESSEE. UNIVERSITY OF: COLLEGE OF VETERINARY MEDICINE"
	replace foia2_institution = "UNIVERSITY OF TENNESSEE HEALTH SCIENCE CENTER" if foia2_institution == "TENNESSEE: HEALTH SCIENCE CENTER - MEMPHIS, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF TENNESSEE MEDICAL CENTER" if foia2_institution == "UNIVERSITY OF TENNESSEE MEMORIAL RESEARCH CENTER"
	replace foia2_institution = "UNIVERSITY OF TEXAS AT ARLINGTON" if foia2_institution == "TEXAS AT ARLINGTON. UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF TEXAS AT AUSTIN" if foia2_institution == "TEXAS AT AUSTIN, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF TEXAS AT DALLAS" if foia2_institution == "TEXAS AT DALLAS. UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF TEXAS AT EL PASO" if foia2_institution == "TEXAS AS EL PASO, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF TEXAS HEALTH CENTER AT TYLER" if foia2_institution == "TEXAS HEALTH SCIENCE CENTER AT TYLER, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF TEXAS HEALTH SCIENCE CENTER AT HOUSTON" if foia2_institution == "TEXAS HOUSTON HEALTH SCIENCE CENTER, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF TEXAS HEALTH SCIENCE CENTER AT SAN ANTONIO" if foia2_institution == "TEXAS HEALTH SCIENCE CENTER AT SAN ANTONIO, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF TEXAS MEDICAL BRANCH AT GALVESTON" if foia2_institution == "TEXAS MEDICAL BRANCH AT GALVESTON, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF TEXAS SOUTHWESTERN MEDICAL CENTER AT DALLAS" if foia2_institution == "TEXAS SOUTHWESTERN, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF TOLEDO HEALTH SCIENCES CENTER" if foia2_institution == "TOLEDO HEALTH SCIENCE CANTER, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF TOLEDO" if foia2_institution == "TOLEDO, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF UTAH" if foia2_institution == "UTAH, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF VERMONT AND STATE AGRICULTURAL COLLEGE" if foia2_institution == "UNIV OF VERMONT"
	replace foia2_institution = "UNIVERSITY OF VIRGINIA AT CHARLOTTESVILLE" if foia2_institution == "VIRGINIA, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF WASHINGTON" if foia2_institution == "WASHINGTON, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF WEST FLORIDA" if foia2_institution == "WEST FLORIDA, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF WISCONSIN AT MADISON" if foia2_institution == "WISCONSIN AT MADISON, UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF WISCONSIN AT MILWAUKEE" if foia2_institution == "WISCONSIN AT MILWAUKEE. UNIVERSITY OF"
	replace foia2_institution = "UNIVERSITY OF WYOMING" if foia2_institution == "WYOMING, UNIVERSITY OF"
	replace foia2_institution = "WAKE FOREST UNIVERSITY HEALTH SCIENCES" if foia2_institution == "WAKE FOREST UNIVERSITY"
	replace foia2_institution = "WEILL MEDICAL COLLEGE OF CORNELL UNIVERSITY" if foia2_institution == "CORNELL UNIVERSITY MEDICAL"

	// ----- create tempfile for merge ----- // 
	tempfile foia2
	save `foia2', replace
	clear
	
	// ----- get relevant institutions ----- //
	import delimited using "${byhand}/relevant_subset.csv", varnames(1) clear
	rename institution foia2_institution
	duplicates drop
	merge 1:m foia2_institution using `foia2'
	keep if _merge == 3
	drop _merge
	
	// ----- export concordance ----- //
	preserve
	keep *institution 
	duplicates drop
	trim_subroutine
	order foia2_institution original_institution
	sort foia2_institution original_institution
	export delimited "${nih_output}/foia2_institution_concordance.csv", replace
	restore
	
	// ----- expand to 12 months ----- //
	expand 12
	bysort foia2_institution year: gen month = _n
	rename rate rate2	
	rename foia2_institution institution
	
	// ----- save foia2 rates tempfile ----- //
	trim_subroutine
	tempfile foia2_noshift
	save `foia2_noshift', replace
	clear

/* 

The following code matches foia2 rates to the existing nicra agreement rates 
starting in July of a given foia2 year and ending in June of the following year
(we determined that these were the most common start and end months for the 
agreement rates). After matching, the code keeps those observations where (a) 
there is at least one overlap between nicra and foia2 rates for a given 
month-year pair and (b) the number of exact matches exceed some specified 
threshold amount of accuracy (e.g., 100% or 90%). 

We leave this code in place in case of future need, but instead we opted to use
the flexible matching system below. 

// ------- foia2 rates ------- //

	// --- data --- //
	use `foia2_noshift', clear

	// --- shift --- //
	replace year = year - 1 if month >= 7
	drop if year == 1981

	// --- merge --- //
	merge 1:1 institution year month using "${nih_output}/nicra_panel.dta"
	drop _merge
	
	// --- foia1 --- //
	rename rate rate1
		
	// --- save --- //
	trim_subroutine
	order institution month year rate1 rate2
	sort institution year month
	save "${nih_output}/nicra_panel.dta", replace
	

	// ----- percents ----- //
	local percents 100 90

	// ----- subsets ----- //

		// --- data --- //
		use "${nih_output}/nicra_panel.dta", clear
	
		// --- both --- //
		drop if missing(rate1) | missing(rate2)
		
		// --- collapse --- //
		gen numobs = 1
		gen equal = 0
		replace equal = 1 if rate1 == rate2 
		collapse (sum) numobs (sum) equal, by(institution)
		
		// --- ratio --- //
		gen keep_ratio = equal/numobs  

		// --- overrides --- //
		
		foreach percent of local percents {
			local rate = `percent'/100
			gen matched`percent' = 0
			replace matched`percent' = 1 if keep_ratio >= `rate'
		}
				
		// --- tempfile --- //
		keep institution matched*
		tempfile matches
		save `matches', replace
		
	// ----- matches ----- //
	
		// --- data --- //
		use "${nih_output}/nicra_panel.dta", clear

		// --- merge --- //
		merge m:1 institution using `matches'
		
			// - error check - //
			count if _merge == 2
			if r(N) != 0 {
				display as error "extra foia2 institutions in relevant panel"
				display as error "to see extra institutions: keep if _merge == 2"
				display as error "remove extra institution (no easy coding solution)"
				exit 1
			}
			
		drop _merge
		
		// --- replace --- //
		foreach percent of local percents {
			gen foia2_`percent'_rate = rate2
			replace foia2_`percent'_rate = . if matched`percent' == 0
		}
		
		// --- drop missing --- //
		drop if missing(rate1) & missing(rate2)
		
	// ----- save ------ //
	trim_subroutine
	save "${nih_output}/nicra_panel.dta", replace
	clear

*/

// We resume active code below. 

	// ----- match foia2 rates to foia1 using algorithm that varies start month ----- //
	
		// --- data --- //
		use "${nih_output}/nicra_panel.dta", clear
			
		// --- foia1 flex subset --- //
		keep institution month year rate1
		duplicates drop
		tempfile foia1_flex_subset
		save `foia1_flex_subset', replace		
			
		// --- foia2 flex subset --- //
		
			// - unique institution names - //
			keep institution 
			duplicates drop
			
			// - merge to foia2 rates (not shifted, i.e., based on Jan-Dec) - //
			merge 1:m institution using `foia2_noshift'
			keep if _merge == 3
			drop _merge 

			// - temporary file save - //
			rename rate2 rate2
			tempfile foia2_flex_subset
			save `foia2_flex_subset', replace
			clear
			
		// --- create empty set to append into --- //
		set obs 1
		gen institution = ""
		tempfile matched_flex
		save `matched_flex', replace
		clear
		
		// --- expaned subset --- //
		forval x = 13(-1)1 {
//		local x = 9
		// x = 01 corresponds to each agreement starting in jan of the year before
		// x = 02 corresponds to each agreement starting in feb of the year before
		// .......................................................................
		// x = 12 corresponds to each agreement starting in dec of the year before
		// x = 13 corresponds to each agreement starting in jan of the year given

			// - data for flex  - //
			use `foia2_flex_subset', clear
			
			// - shift by x months - //
			replace year = year -1 if month >= `x'
			sort institution year month
			drop if year == 1981

			// - merge and document the "x" month - //
			merge 1:1 institution year month using `foia1_flex_subset', nogenerate
			gen flex_month = `x'
			drop if missing(rate1) & missing(rate2)
			
			// - create tempfile of match - //
			order institution year month rate1 rate2
			tempfile matched 
			save `matched', replace			
		
			// - both - //
			drop if missing(rate1) | missing(rate2)
			
			// - collapse to determine ratio of match - //
			gen numobs = 1
			gen equal = 0
			replace equal = 1 if rate1 == rate2 
			collapse (sum) numobs (sum) equal, by(institution)

			// - create ratio of match (ratio = 1 for perfect match) - //
			gen keep_ratio = equal/numobs  
			gen matched_flex = 0
			replace matched_flex = 1 if keep_ratio == 1
			
			// - keep perfect matches - //
			keep institution matched_flex
			tempfile matches
			save `matches', replace
			
			// - merge to tempfile matched - //
			use `matched', clear
			merge m:1 institution using `matches', nogenerate
			
			// - resubset dropping those that already had a perfect match - //
			count if matched_flex == 1
			if r(N) != 0 {
			
				// + matched + //
				preserve
				keep if matched_flex == 1
				keep institution year month rate2 matched_flex flex_month
				duplicates drop
				append using `matched_flex'
				drop if missing(institution)
				save `matched_flex', replace
				
				// + unmatched + //
				keep institution 
				duplicates drop
				tempfile todrop
				save `todrop', replace
				
				restore
				drop if matched_flex == 1
				keep institution month year rate1 
				duplicates drop
				save `foia1_flex_subset', replace
				
				use `foia2_flex_subset', clear
				merge m:1 institution using `todrop'
				drop if _merge == 3
				drop _merge
				duplicates drop 
				save `foia2_flex_subset', replace
			}
			
			// - clear - //
			clear
	}		
		
		// --- merge --- //
		use "${nih_output}/nicra_panel.dta", clear
		merge 1:1 institution year month using `matched_flex', nogenerate
		drop matched_flex
		
		// --- save --- //
		trim_subroutine
		save "${nih_output}/nicra_panel.dta", replace
		clear	
		
// ------- fill out panel ------- //

	// ----- month ----- //
	set obs 12
	gen month = _n
	tempfile month
	save `month', replace
	clear
	
	// ----- year ----- //
	use "${nih_output}/nicra_panel.dta", clear
	sum year
	local minyear = r(min)
	local numyear = r(max) - r(min) + 1
	clear
		
	set obs `numyear'
	gen year = `minyear' - 1 + _n
	
	// ----- combine ----- //
	cross using `month'
	tempfile scaffold
	save `scaffold', replace
	
	// ----- institutions ----- //
	use "${nih_output}/nicra_panel.dta", clear
	keep institution 
	duplicates drop
	
	cross using `scaffold'
	
	// ----- merge ----- //
	merge 1:1 institution month year using "${nih_output}/nicra_panel.dta", nogenerate
	gen rate_n = rate1
	replace rate_n = rate2 if missing(rate_n)
	
	// ----- year subset ----- //
	drop if year < 1982 | year > 2007
		
	// ----- save ----- //
	order institution agreement_date month year rate_type rate1 rate2 rate_n location applicable 
	sort inst year month 
	trim_subroutine 
	save "${nih_output}/nicra_panel.dta", replace
	export delimited "${nih_output}/nicra_panel.csv", replace
	clear
