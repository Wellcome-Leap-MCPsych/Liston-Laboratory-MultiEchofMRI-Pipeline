#!/bin/bash
# CJL; (cjl2007@med.cornell.edu)

Subject=$1
StudyFolder=$2
Subdir="$StudyFolder"/"$Subject"
RESOURCES=$3
T1wTemplate2mm=$4
NTHREADS=$5 

# count the number of sessions
sessions=("$Subdir"/func/rest/session_*)
sessions=$(seq 1 1 "${#sessions[@]}")

# sweep the sessions;
for s in $sessions ; do

	# count number of runs for this session;
	runs=("$Subdir"/func/rest/session_"$s"/run_*)
	runs=$(seq 1 1 "${#runs[@]}")

	# sweep the runs;
	for r in $runs ; do

		# "data_dirs.txt" contains 
		# dir. paths to every scan. 
		echo /session_"$s"/run_"$r" \
		>> "$Subdir"/data_dirs.txt  

	done

done

# define a list of directories;
data_dirs=$(cat "$Subdir"/data_dirs.txt) # note: this is used for parallel processing purposes.
rm "$Subdir"/data_dirs.txt # remove intermediate file;

func () {

	# make a tmp dir. 
	mkdir "$2"/func/rest/"$3"/vols/

	# define some acq. parameters;
	te=$(cat "$2"/func/rest/"$3"/te.txt)
	tr=$(cat "$2"/func/rest/"$3"/tr.txt)
	n_te=0 # set to zero;

	# sweep the te;
	for i in $te ; do

		# track which te we are on
		n_te=`expr $n_te + 1` # tick;

		# skip the longer te;
		if [[ $i < 50 ]] ; then 

			# split original 4D resting-state file into single 3D vols.;
			fslsplit "$2"/func/unprocessed/rest/"$3"/Rest*_E"$n_te".nii.gz \
			"$2"/func/rest/"$3"/vols/E"$n_te"_

		fi
	
	done

	# sweep through all of the individual volumes;
	for i in $(seq -f "%04g" 0 $((`fslnvols "$2"/func/unprocessed/rest/"$3"/Rest*_E1.nii.gz` - 1))) ; do

	  	# combine te;
	  	fslmerge -t "$2"/func/rest/"$3"/vols/AVG_"$i".nii.gz "$2"/func/rest/"$3"/vols/E*_"$i".nii.gz > /dev/null 2>&1  	
		fslmaths "$2"/func/rest/"$3"/vols/AVG_"$i".nii.gz -Tmean "$2"/func/rest/"$3"/vols/AVG_"$i".nii.gz

	done

	# merge the images;
	fslmerge -t "$2"/func/rest/"$3"/Rest_AVG.nii.gz "$2"/func/rest/"$3"/vols/AVG_*.nii.gz # note: used for estimating head motion;
	fslmerge -t "$2"/func/rest/"$3"/Rest_E1.nii.gz "$2"/func/rest/"$3"/vols/E1_*.nii.gz # note: used for estimating (very rough)bias field;
	rm -rf "$2"/func/rest/"$3"/vols/ # remove temporary dir.

	# use the first echo (w/ least amount of signal dropout) to estimate bias field;
	fslmaths "$2"/func/rest/"$3"/Rest_E1.nii.gz -Tmean "$2"/func/rest/"$3"/Mean.nii.gz
	N4BiasFieldCorrection -d 3 -i "$2"/func/rest/"$3"/Mean.nii.gz -s 1 -o ["$2"/func/rest/"$3"/Mean_Restored.nii.gz,"$2"/func/rest/"$3"/Bias_field.nii.gz] # estimate field inhomog.; 
	rm "$2"/func/rest/"$3"/Rest_E1.nii.gz # remove intermediate file;

	# resample bias field image (ANTs --> FSL orientation);
	flirt -in "$2"/func/rest/"$3"/Bias_field.nii.gz -ref "$2"/func/rest/"$3"/Mean.nii.gz -applyxfm \
	-init "$RESOURCES"/ident.mat -out "$2"/func/rest/"$3"/Bias_field.nii.gz -interp spline

	# remove signal bias; 
	fslmaths "$2"/func/rest/"$3"/Rest_AVG.nii.gz \
	-div "$2"/func/rest/"$3"/Bias_field.nii.gz \
	"$2"/func/rest/"$3"/Rest_AVG.nii.gz

	# remove some intermediate files;
	rm "$2"/func/rest/"$3"/Mean*.nii.gz
	rm "$2"/func/rest/"$3"/Bias*.nii.gz

	# run an initial MCFLIRT to get rp. estimates prior to any slice time correction;
	mcflirt -dof 6 -stages 3 -plots -in "$2"/func/rest/"$3"/Rest_AVG.nii.gz -r "$2"/func/rest/"$3"/SBref.nii.gz -out "$2"/func/rest/"$3"/mcf
	rm "$2"/func/rest/"$3"/mcf.nii.gz # remove .nii output; not used moving forward 

	# perform slice time correction; using custom timing file;
	slicetimer -i "$2"/func/rest/"$3"/"$3"/Rest_AVG.nii.gz \
	-o "$2"/func/rest/"$3"/Rest_AVG.nii.gz -r $tr \
	--tcustom="$2"/func/rest/"$3"/slice_times.txt 

	# now run another MCFLIRT; specify average sbref as ref. vol & output transformation matrices;
	mcflirt -dof 6 -mats -stages 3 -in "$2"/func/rest/"$3"/Rest_AVG.nii.gz -r "$2"/func/xfms/rest/SBref_avg.nii.gz -out "$2"/func/rest/"$3"/Rest_AVG_mcf 
	rm "$2"/func/rest/"$3"/Rest_AVG*.nii.gz # delete intermediate images; not needed moving forward;

	# sweep all of the echoes; 
	for e in $(seq 1 1 "$n_te") ; do

		# copy over echo "e"; 
		cp "$2"/func/unprocessed/rest/"$3"/Rest*_E"$e".nii.gz \
		"$2"/func/rest/"$3"/Rest_E"$e".nii.gz

		# perform slice time correction using custom timing file;
		slicetimer -i "$2"/func/rest/"$3"/Rest_E"$e".nii.gz \
		--tcustom="$2"/func/rest/"$3"/slice_times.txt \
		-r $tr -o "$2"/func/rest/"$3"/Rest_E"$e".nii.gz

		# split original data into individual volumes;
		fslsplit "$2"/func/rest/"$3"/Rest_E"$e".nii.gz \
		"$2"/func/rest/"$3"/Rest_AVG_mcf.mat/vol_ -t 

		# define affine transformation 
		# matrices and associated target images; 
		mats=("$2"/func/rest/"$3"/Rest_AVG_mcf.mat/MAT_*)
	    images=("$2"/func/rest/"$3"/Rest_AVG_mcf.mat/vol_*.nii.gz)

		# sweep through the split images;
		for (( i=0; i<${#images[@]}; i++ )); do

			# warp image into 2mm MNI atlas space using a single spline transformation; 
			applywarp --interp=spline --in="${images["$i"]}" --premat="${mats["$i"]}" --warp="$2"/func/xfms/rest/SBref2nonlin_warp.nii.gz --out="${images["$i"]}" --ref="$1"
			fslmaths "${images["$i"]}" -uthr 0 -mul -1 -bin "$2"/func/rest/"$3"/Rest_AVG_mcf.mat/bad_voxels.nii.gz # remove negative values created by spline interp.;
 			wb_command -volume-dilate "${images["$i"]}" 10 NEAREST "${images["$i"]}" -bad-voxel-roi "$2"/func/rest/"$3"/Rest_AVG_mcf.mat/bad_voxels.nii.gz # note: 10mm is arbitrary; 99% of the time these voxels are not "in-brain"

		done

		# merge corrected images into a single file;
		fslmerge -t "$2"/func/rest/"$3"/Rest_E"$e"_nonlin.nii.gz \
		"$2"/func/rest/"$3"/Rest_AVG_mcf.mat/*.nii.gz

		# perform a brain extraction
		fslmaths "$2"/func/rest/"$3"/Rest_E"$e"_nonlin.nii.gz \
		-mas "$2"/func/xfms/rest/T1w_nonlin_brain_2mm_mask.nii.gz \
		"$2"/func/rest/"$3"/Rest_E"$e"_nonlin.nii.gz # note: this step reduces file size, which is generally desirable but not absolutely needed.

		# remove some intermediate files;
		rm "$2"/func/rest/"$3"/Rest_AVG_mcf.mat/*.nii.gz # split volumes
		rm "$2"/func/rest/"$3"/Rest_E"$e".nii.gz # raw data 

	done

	# rename mcflirt transform dir.;
	mv "$2"/func/rest/"$3"/*_mcf*.mat \
	"$2"/func/rest/"$3"/MCF

	# use the first echo (w/ least amount of signal dropout) to estimate bias field;
	fslmaths "$2"/func/rest/"$3"/Rest_E1_nonlin.nii.gz -Tmean "$2"/func/rest/"$3"/Mean.nii.gz
	N4BiasFieldCorrection -d 3 -i "$2"/func/rest/"$3"/Mean.nii.gz -s 1 -o ["$2"/func/rest/"$3"/Mean_Restored.nii.gz,"$2"/func/rest/"$3"/Bias_field.nii.gz] # estimate field inhomog.; 
	flirt -in "$2"/func/rest/"$3"/Bias_field.nii.gz -ref "$2"/func/rest/"$3"/Mean.nii.gz -applyxfm -init "$RESOURCES"/ident.mat -out "$2"/func/rest/"$3"/Bias_field.nii.gz -interp spline # resample bias field image (ANTs --> FSL orientation);

	# sweep all of the echoes; 
	for e in $(seq 1 1 "$n_te") ; do

		# correct for signal inhomogenties;
		fslmaths "$2"/func/rest/"$3"/Rest_E"$e".nii.gz -div \
		"$2"/func/rest/"$3"/Bias_field.nii.gz \
		"$2"/func/rest/"$3"/Rest_E"$e".nii.gz

	done

	# remove some intermediate files;
	rm "$2"/func/rest/"$3"/Mean*.nii.gz

}

export -f func # correct for head motion and warp to atlas space in single spline warp
parallel --jobs $NTHREADS func ::: $T1wTemplate2mm ::: $Subdir ::: $data_dirs > /dev/null 2>&1  
