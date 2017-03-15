function free_energy_sim_patch_size(subj_info, session_num, invfoi, SNR, varargin)

% Parse inputs
defaults = struct('surf_dir', 'd:\pred_coding\surf', 'mri_dir', 'd:\pred_coding\mri',...
    'dipole_moment', 10, 'nsims', 60);  %define default values
params = struct(varargin{:});
for f = fieldnames(defaults)',
    if ~isfield(params, f{1}),
        params.(f{1}) = defaults.(f{1});
    end
end

% Copy already-inverted file
rawfile=fullfile('D:\pred_coding\analysis\',subj_info.subj_id, num2str(session_num), 'grey_coreg\EBB\p0.4\instr\f15_30', sprintf('r%s_%d.mat',subj_info.subj_id,session_num));
% Output directory
out_path=fullfile('D:\layer_sim\results',subj_info.subj_id,num2str(session_num));
if exist(out_path,'dir')~=7
    mkdir(out_path);
end
% New file to work with
newfile=fullfile(out_path, sprintf('%s_%d.mat',subj_info.subj_id,session_num));

% White and pial meshes for this subject
allmeshes=strvcat(fullfile(params.surf_dir,[subj_info.subj_id subj_info.birth_date '-synth'],'surf','ds_white.hires.deformed.surf.gii'),...
    fullfile(params.surf_dir,[subj_info.subj_id subj_info.birth_date '-synth'],'surf','ds_pial.hires.deformed.surf.gii'));
Nmesh=size(allmeshes,1);

spm('defaults', 'EEG');
spm_jobman('initcfg'); 

patch_sizes=[5 10];

%for sp=1:length(patch_sizes)
for sp=2:length(patch_sizes)
    sim_patch_size=patch_sizes(sp);
    for rp=1:length(patch_sizes)
        reconstruct_patch_size=patch_sizes(rp);

        out_file=sprintf('allcrossF_f%d_%d_SNR%d_dipolemoment%d_sim%d_reconstruct%d.mat',invfoi(1),invfoi(2),SNR,params.dipole_moment,sim_patch_size,reconstruct_patch_size);

        % Copy file to foi_dir
        clear jobs
        matlabbatch=[];
        matlabbatch{1}.spm.meeg.other.copy.D = {rawfile};
        matlabbatch{1}.spm.meeg.other.copy.outfile = newfile;
        spm_jobman('run', matlabbatch);
        
        % Create smoothed meshes
        %patch_extent_mm=-5; %5 approx mm
        for meshind=1:Nmesh,
            [smoothkern]=spm_eeg_smoothmesh_mm(deblank(allmeshes(meshind,:)),sim_patch_size);
        end

        %% Setup simulation - number of sources, list of vertices to simulate on
        mesh_one=gifti(allmeshes(1,:));
        nverts=size(mesh_one.vertices,1);
        rng(0);
        simvertind=randperm(nverts); %% random list of vertex indices to simulate sources on
        Nsim=60; %% number of simulated sources

        %% for MSP  or GS or ARD
        % Number of patches as priors
        Npatch=round(Nsim*1.5);
        % so use all vertices that will be simulated on (plus a few more) as MSP priors
        Ip=simvertind(1:Npatch);
        % Save priors
        patchfilename=fullfile(out_path, 'temppatch.mat');
        save(patchfilename,'Ip');

        % Inversion method to use
        methodnames={'EBB','IID','COH','MSP'}; %% just 1 method for now
        Nmeth=length(methodnames);

        % Inversion parameters
        invwoi=[100 500];
        % Number of cross validation folds
        Nfolds=1;
        % Percentage of test channels in cross validation
        ideal_pctest=0;
        % Use all available spatial modes
        ideal_Nmodes=[];

        % All F values and cross validation errors
        % meshes simulated on x number of simulations x meshes reconstructed onto x
        % num methods x num cross validation folds
        allcrossF=zeros(Nmesh,Nsim,Nmesh,Nmeth);
        
        % Simulate sources on each mesh
        for simmeshind=1:Nmesh, %% choose mesh to simulate on

            simmesh=deblank(allmeshes(simmeshind,:));

            %% coregister to correct mesh
            filename=deblank(newfile);
            matlabbatch=[];
            matlabbatch{1}.spm.meeg.source.headmodel.D = {filename};
            matlabbatch{1}.spm.meeg.source.headmodel.val = 1;
            matlabbatch{1}.spm.meeg.source.headmodel.comment = '';
            matlabbatch{1}.spm.meeg.source.headmodel.meshing.meshes.custom.mri = {fullfile(params.mri_dir,[subj_info.subj_id subj_info.birth_date], [subj_info.headcast_t1 ',1'])};
            matlabbatch{1}.spm.meeg.source.headmodel.meshing.meshes.custom.cortex = {simmesh};
            matlabbatch{1}.spm.meeg.source.headmodel.meshing.meshes.custom.iskull = {''};
            matlabbatch{1}.spm.meeg.source.headmodel.meshing.meshes.custom.oskull = {''};
            matlabbatch{1}.spm.meeg.source.headmodel.meshing.meshes.custom.scalp = {''};
            matlabbatch{1}.spm.meeg.source.headmodel.meshing.meshres = 2;
            matlabbatch{1}.spm.meeg.source.headmodel.coregistration.coregspecify.fiducial(1).fidname = 'nas';
            matlabbatch{1}.spm.meeg.source.headmodel.coregistration.coregspecify.fiducial(1).specification.type = subj_info.nas;
            matlabbatch{1}.spm.meeg.source.headmodel.coregistration.coregspecify.fiducial(2).fidname = 'lpa';
            matlabbatch{1}.spm.meeg.source.headmodel.coregistration.coregspecify.fiducial(2).specification.type = subj_info.lpa;
            matlabbatch{1}.spm.meeg.source.headmodel.coregistration.coregspecify.fiducial(3).fidname = 'rpa';
            matlabbatch{1}.spm.meeg.source.headmodel.coregistration.coregspecify.fiducial(3).specification.type = subj_info.rpa;
            matlabbatch{1}.spm.meeg.source.headmodel.coregistration.coregspecify.useheadshape = 0;
            matlabbatch{1}.spm.meeg.source.headmodel.forward.eeg = 'EEG BEM';
            matlabbatch{1}.spm.meeg.source.headmodel.forward.meg = 'Single Shell';
            spm_jobman('run', matlabbatch);

            Dmesh=spm_eeg_load(filename);    

            %% now simulate sources on this mesh
            for s=1:Nsim,
                %% get location to simulate dipole on this mesh
                simpos=Dmesh.inv{1}.mesh.tess_mni.vert(simvertind(s),:); 

                % Simulate source 
                matlabbatch=[];
                matlabbatch{1}.spm.meeg.source.simulate.D = {filename};
                matlabbatch{1}.spm.meeg.source.simulate.val = 1;
                matlabbatch{1}.spm.meeg.source.simulate.prefix = sprintf('sim_mesh%d_source%d',simmeshind,s);
                matlabbatch{1}.spm.meeg.source.simulate.whatconditions.all = 1;
                matlabbatch{1}.spm.meeg.source.simulate.isinversion.setsources.woi = invwoi;
                matlabbatch{1}.spm.meeg.source.simulate.isinversion.setsources.isSin.foi = mean(invfoi);
                matlabbatch{1}.spm.meeg.source.simulate.isinversion.setsources.dipmom = [params.dipole_moment sim_patch_size];
                matlabbatch{1}.spm.meeg.source.simulate.isinversion.setsources.locs = simpos;
                if abs(params.dipole_moment)>0
                    matlabbatch{1}.spm.meeg.source.simulate.isSNR.setSNR = SNR;               
                else
                    matlabbatch{1}.spm.meeg.source.simulate.isSNR.whitenoise = 100;
                end
                [a,b]=spm_jobman('run', matlabbatch);

                % Load simulated dataset
                simfilename=a{1}.D{1};        
                Dsim=spm_eeg_load(simfilename);        

                %% now reconstruct onto all the meshes and look at cross val and F vals
                for meshind=1:Nmesh,

                    % Coregister simulated dataset to reconstruction mesh
                    matlabbatch=[];
                    matlabbatch{1}.spm.meeg.source.headmodel.D = {simfilename};
                    matlabbatch{1}.spm.meeg.source.headmodel.val = 1;
                    matlabbatch{1}.spm.meeg.source.headmodel.comment = '';
                    matlabbatch{1}.spm.meeg.source.headmodel.meshing.meshes.custom.mri = {fullfile(params.mri_dir,[subj_info.subj_id subj_info.birth_date], [subj_info.headcast_t1 ',1'])};
                    matlabbatch{1}.spm.meeg.source.headmodel.meshing.meshes.custom.cortex = {deblank(allmeshes(meshind,:))};
                    matlabbatch{1}.spm.meeg.source.headmodel.meshing.meshes.custom.iskull = {''};
                    matlabbatch{1}.spm.meeg.source.headmodel.meshing.meshes.custom.oskull = {''};
                    matlabbatch{1}.spm.meeg.source.headmodel.meshing.meshes.custom.scalp = {''};
                    matlabbatch{1}.spm.meeg.source.headmodel.meshing.meshres = 2;
                    matlabbatch{1}.spm.meeg.source.headmodel.coregistration.coregspecify.fiducial(1).fidname = 'nas';
                    matlabbatch{1}.spm.meeg.source.headmodel.coregistration.coregspecify.fiducial(1).specification.type = subj_info.nas;
                    matlabbatch{1}.spm.meeg.source.headmodel.coregistration.coregspecify.fiducial(2).fidname = 'lpa';
                    matlabbatch{1}.spm.meeg.source.headmodel.coregistration.coregspecify.fiducial(2).specification.type = subj_info.lpa;
                    matlabbatch{1}.spm.meeg.source.headmodel.coregistration.coregspecify.fiducial(3).fidname = 'rpa';
                    matlabbatch{1}.spm.meeg.source.headmodel.coregistration.coregspecify.fiducial(3).specification.type = subj_info.rpa;
                    matlabbatch{1}.spm.meeg.source.headmodel.coregistration.coregspecify.useheadshape = 0;
                    matlabbatch{1}.spm.meeg.source.headmodel.forward.eeg = 'EEG BEM';
                    matlabbatch{1}.spm.meeg.source.headmodel.forward.meg = 'Single Shell';            
                    spm_jobman('run', matlabbatch);

                    % Setup spatial modes for cross validation
                    spatialmodesname=[Dsim.path filesep 'testmodes.mat'];
                    [spatialmodesname,Nmodes,pctest]=spm_eeg_inv_prep_modes_xval(simfilename, ideal_Nmodes, spatialmodesname, Nfolds, ideal_pctest);

                    % Resconstruct using each method
                    for methind=1:Nmeth,                

                        % Do inversion of simulated data with this surface
                        matlabbatch=[];
                        matlabbatch{1}.spm.meeg.source.invertiter.D = {simfilename};
                        matlabbatch{1}.spm.meeg.source.invertiter.val = 1;
                        matlabbatch{1}.spm.meeg.source.invertiter.whatconditions.all = 1;
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.invfunc = 'Classic';
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.invtype = methodnames{methind}; %;
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.woi = invwoi;
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.foi = invfoi;
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.hanning = 1;
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.isfixedpatch.fixedpatch.fixedfile = {patchfilename}; % '<UNDEFINED>';
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.isfixedpatch.fixedpatch.fixedrows = 1; %'<UNDEFINED>';
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.patchfwhm =[-reconstruct_patch_size]; %% NB A fiddle here- need to properly quantify
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.mselect = 0;
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.nsmodes = Nmodes;
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.umodes = {spatialmodesname};
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.ntmodes = [];
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.priors.priorsmask = {''};
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.priors.space = 1;
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.restrict.locs = zeros(0, 3);
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.restrict.radius = 32;
                        matlabbatch{1}.spm.meeg.source.invertiter.isstandard.custom.outinv = '';
                        matlabbatch{1}.spm.meeg.source.invertiter.modality = {'All'};
                        matlabbatch{1}.spm.meeg.source.invertiter.crossval = [pctest Nfolds];                                
                        [a1,b1]=spm_jobman('run', matlabbatch);

                        % Load inversion - get cross validation error end F
                        Drecon=spm_eeg_load(simfilename);                
                        allcrossF(simmeshind,s,meshind,methind)=Drecon.inv{1}.inverse.crossF;


                    end; % for methind                        
                end; %% for reconstruction mesh (meshind)
                close all;
            end; % for s (sources)
        end; % for simmeshind (simulatiom mesh)
        save(fullfile(out_path,out_file),'allcrossF');

        for methind=1:Nmeth,                
            figure(methind);clf;

            % For each simulated mesh
            for simmeshind=1:Nmesh,
                [path,file,ext]=fileparts(deblank(allmeshes(simmeshind,:)));
                x=strsplit(file,'.');
                y=strsplit(x{1},'_');
                simmeshname=y{2};
                % other mesh index (assuming there are just 2 meshes)
                otherind=setxor(simmeshind,1:Nmesh);
                [path,file,ext]=fileparts(deblank(allmeshes(otherind,:)));
                x=strsplit(file,'.');
                y=strsplit(x{1},'_');
                othermeshname=y{2};

                % F reconstructed on true - reconstructed on other
                % num simulations x number of folds
                truotherF=squeeze(allcrossF(simmeshind,:,simmeshind,methind)-allcrossF(simmeshind,:,otherind,methind));
                subplot(Nmesh,1,simmeshind);
                bar(truotherF)
                xlabel('Simulation')
                ylabel('Free energy diff');
                title(sprintf('Free energy, %s, %s-%s',methodnames{methind},simmeshname,othermeshname));        

            end

        end

    end
end