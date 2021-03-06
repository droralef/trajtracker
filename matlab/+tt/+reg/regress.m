function result = regress(expData, regressionType, depVarSpec, predictorSpec, varargin)
% ----------------------------------------------------------
% result = regress(expData, regType, depVar, pred, ...) -
% Run regression per subject.
% Both the dependent var and the predictors may be dynamic, i.e.,
% have different values per time point.
% 
% Returns a tt.reg.OneRR object.
% 
% Mandatory arguments:
% =====================
% regType: reg, step, corr, pointbiserial, or logglm
% depVarSpec: Specification of dependent variable. 
% predictorSpec: Specification of predictors (used by the get-measure function)
% 
% The dependent variable / predictor specifications are turned into actual
% values using one of two functions:
% - <a href="matlab:help tt.reg.getTrialMeasures">tt.reg.getTrialMeasures</a> defines per-trial measures
%   (which have a single value per trial, e.g., movement time).
% - <a href="matlab:help tt.reg.getTrialDynamicMeasures">tt.reg.getTrialDynamicMeasures</a> defines measures that
%   change during the course of a trial (e.g., x coordinate).
% To see the full list of supported predictors, look inside these functions.
% 
% If a predictor specification / the dependent variable specification are strings
% starting with '#', this indicates that it is per-time point.
% 
% To add your own variables/predictors, you can create a custom version of
% these functions and use the 'FMeasureFunc' or 'DMeasureFunc' flags (see
% details below).
% 
%
% Optional arguments:
% ====================
% 
% ---- Filtering
% 
% AvgTrials: use expData.AvgTrialsAbs (rather than raw expData.Trials)
% TrialFilter <function>: @(trial)->BOOL or @(trial,expData)->BOOL
% TPFilter <function>: @(trial,rowNum)->BOOL - filter for specific time point
% MinSPRatio <ratio>: If the #samples/#predictors ratio is less than that,
%                     regression will not be run. Default value: 3
% TrialsConsFunc <func>: function that consolidates trials: after trials
%                        were filtered, but before running the regression,
%                        this function switches the set of trials by
%                        another set of trials (e.g., you can use this for
%                        custom-defined averaging of trials).
%                        Signature: @(trials,expData)->trials
% 
% ---- Specifying predictors and the dependent variable
% 
% TpDep: a flag indicating that the dependent variable is per time
%        point rather than per trial. 
%        Instead of this flag, you can also add a '#' prefix to the 
%        'depVarSpec' argument of regress()
% FMeasureFunc <func>: Function to return a fixed (per-trial) measure
%                      Same signature as tt.reg.getTrialMeasures.
%                      Example: tt.reg.customize.getMyTrialMeasures
% DMeasureFunc <func>: Function to return a dynamic (per-timepoint) measure
%                      Same signature as tt.reg.getTrialDynamicMeasures
%                      Example: tt.reg.customize.getMyTrialDynamicMeasures
% 
% ---- Specifying time points to regress
% 
% We can run one regression per time point, but "time point" is now a more
% abstract concept - it's a way to group times from different trials.
% Usually, "time point" refers to "time from the trial start" (and a row in
% the trajectory matrix), meaning that in one regressions, we take row #N
% from all trials. But you can choose a row per trial in any way you want
% (e.g., regress a certain Y coordinate from all trials, or regress the
% time points at a certain distance from the end of trial).
% 
% rows <row-numbers>: explicitly specify time points to regress. By
%                     default, this refers to row numbers in the trajectory
%                     matrix.
% dt <seconds>: delta-time (seconds) between subsequent per-timepoint
%               regressions.
% TpToRowFunc <func>: a function that translates time points into row numbers.
%                     Signature: @(time_points, trial) -> row_nums
% Row1OffsetFunc <func>: A similar idea, assuming that you group trials by
%                        row numbers (abs time) and just want to shift each
%                        trial with a fixed offset.
%                        Signature: @(trial)->rownum
%                        The function should return the number of row#1
%                        If this feature is used, the "times" in regression
%                        results  are specified with respect to the
%                        first row (i.e., time=0 is the first row), and
%                        the 'MaxTime' argument behaves accordingly.
% Row1OffsetAttr <attr>: Similar to Row1OffsetFunc, but this assumes that
%                        the offset was already calculated per trial and
%                        saved on a custom attribute.
% TPY: One regression per y coordinate. Use this in conjunction with the "rows" 
%      argument, which should indicate the y values.
%      In the results, "times" will be the y coordinate.
% 
% ---- Misc
% 
% FullStat: save full regression statistics in the results object.
% RMessage: message to print to console when starting the regression.
%           Available keywords: $SUBJID$, $NTRIALS$, $NTP$ (# time points)
% V: verbose - print more debug messages
% Silent: don't print anything
% SaveInput <filename.mat>: Save in this file the regression input data, i.e.,
%           the values of the predictors and the dependent variable. This
%           is intended for debugging.
% Progress [i, n]: the regression printout message will indicate that this is
%                  is subject #i out of n.

    [predictorSpec, fixedPred] = fixMeasureSpec(predictorSpec);
    onlyFixedPredictors = sum(fixedPred) == length(fixedPred);
    [depVarSpec, fixedDepVar] = fixMeasureSpec(depVarSpec);
    
    [timePoints, trimTimePointsByTrajEnd, getTrialsFunc, trialFilters, consolidateTrialsFunc, ...
        timePointFilters, fixedDepVar, saveRegressionInputFilename, ...
        minSamplesToPredictorsRatio, getTrialMeasureFunc, getDynamicMeasureFunc, outputFullStats, ...
        timePointToRowFunc, getTimePerTpFunc, verbose, ...
        regressionStartMsg, printRegressionMsg, isSilent, progressInfo] = parseArgs(varargin, expData, onlyFixedPredictors, fixedDepVar);
    
    %-- Get the trials to work on
    allTrials = getTrialsFunc(expData);
    trialsToRegress = tt.util.filterTrials(allTrials, trialFilters);
    if ~isempty(consolidateTrialsFunc), trialsToRegress = consolidateTrialsFunc(trialsToRegress, expData); end
    if length(trialsToRegress) < 2*length(predictorSpec)
        error('There are %d predictors but only %d trials - that''s not enough', length(predictorSpec), length(trialsToRegress));
    end

    %-- Get dependent and independent factors
    [predValues, predNames, predDesc, depVarValues, depVarDesc, rowNums, includeTrial] = ...
        getRegressionData(trialsToRegress, timePoints);
    
    %-- Filter trials
    [trialsToRegress, predValues, depVarValues, rowNums, includeTrial, nTimePoints] = ...
        removeUnregressableTrials(trialsToRegress, predValues, depVarValues, rowNums, includeTrial);
    
    %-- Get absolute time per time point
    times = getTimePerTpFunc(timePoints, trialsToRegress, rowNums);
    
    %-- Save for debugging
    if ~isempty(saveRegressionInputFilename)
        trialsToRegressInds = arrayfun(@(t)t.TrialIndex, trialsToRegress); %#ok<NASGU>
        save(saveRegressionInputFilename, 'predValues', 'depVarValues', 'times', 'predNames', 'trialsToRegressInds');
    end

    nPredictors = length(predictorSpec) + 1;  % The "+1" is the const factor
    
    if length(trialsToRegress) < nPredictors * minSamplesToPredictorsRatio
        error('There are only %d trials. This is insufficient for %d predictors (including const). Minimal trial/predictor ratio = %.2f', ...
            length(trialsToRegress), nPredictors, minSamplesToPredictorsRatio);
    end
    
    %-- tell user we're starting
    regressionEndMsg = printStartMessage(printRegressionMsg, regressionStartMsg, expData, length(trialsToRegress), length(timePoints));
    
    result = createEmptyRR(predNames, times);
    calcVariance(result, predValues, depVarValues, nTimePoints);
    result.PredictorDesc = predDesc;
    result.DependentVarDesc = depVarDesc{1};
    
    %-- The parameters used to run the regression
    result.RegressionParams.PredictorSpec = predictorSpec;
    result.RegressionParams.DepVarSpec = depVarSpec;
    result.RegressionParams.FixedPred = fixedPred;
    result.RegressionParams.FixedDepVar = fixedDepVar;
    result.RegressionParams.GetTrialMeasuresFunc = getTrialMeasureFunc;
    result.RegressionParams.GetDynamicMeasuresFunc = getDynamicMeasureFunc;
    result.RegressionParams.ConsolidateTrialsFunc = consolidateTrialsFunc;
    
    % Loop through time points
    for iTP = 1:nTimePoints
        
        if nTimePoints > length(includeTrial)
            disp('WARNING: something strange happens here');
        end
        
        if sum(includeTrial(:,iTP)) == 0 || sum(includeTrial(:,iTP)) < nPredictors * minSamplesToPredictorsRatio
            %-- No trials to regress, or not enough trials to regress
            result = updateResults(result, tt.reg.internal.invalidRegResults(nPredictors), iTP);
            if ~isSilent, fprintf('X'); end
            continue;
        end
        
        currPred = predValues(includeTrial(:,iTP), :, iif(onlyFixedPredictors, 1, iTP));
        currDepVar = depVarValues(includeTrial(:,iTP), iif(fixedDepVar, 1, iTP));
        
        oneRR = tt.reg.internal.runSingleRegression(regressionType, currPred, currDepVar, 'Silent');
        
        result = updateResults(result, oneRR, iTP);
        
        if nTimePoints > 1
            if ~isSilent, fprintf(iif(isnan(oneRR.beta(end)), 'X', '.')); end
        end
        
    end
    
    if ~isSilent, fprintf(regressionEndMsg); end
    
    result.MaxMovementTime = expData.MaxMovementTime;
    
    
    %----------------------------------------------------------------------
    % Fix the predictor-spec: If a predictor name starts with '#', this does
    % not count as part of the predictor name; it is merely an indication
    % that the predictor is per time point.
    % 
    % Returns:
    % spec - same as input, but stripped from the leading '#' character
    % isFixed - array of boolean flags, same size as 'spec', indicating
    %           whether each specifier is a per-trial measure (true) or 
    %           a per time point measure (false)
    % 
    function [spec, isFixed] = fixMeasureSpec(spec)
        
        single = ischar(spec);
        if single
            spec = {spec};
        end
        
        isFixed = true(1, length(spec));
        
        for i = 1:length(spec)
            if ~isempty(spec{i}) && spec{i}(1) == '#'
                isFixed(i) = false;
                spec{i} = spec{i}(2:end);
            end
        end
        
        if single, spec = spec{1}; end
        
    end

    %-------------------------------------------
    function regressionEndMsg = printStartMessage(printRegressionMsg, regressionStartMsg, expData, nTrials, nTimePoints)
        regressionEndMsg = '';
        
        if printRegressionMsg
            if isempty(regressionStartMsg)
                %-- Default message
                if fixedDepVar && onlyFixedPredictors
                    regressionStartMsg = '.';
                else
                    regressionStartMsg = 'Regressing $SUBJID$$PROGRESS$ ($NTRIALS$ trials, $NTP$ time points)\n';
                end
            end
            
            if (~isempty(regressionStartMsg) && regressionStartMsg(end) == 10) || (length(regressionStartMsg)>1 && strcmpi(regressionStartMsg(end-1:end), '\n'))
                regressionEndMsg = '\n';
            end
        else
            %-- Don't print any message when the function runs
            regressionStartMsg = '';
        end
        
        %-- Replace keywords in used-defined message
        regressionStartMsg = strrep(regressionStartMsg, '$SUBJID$', upper(expData.SubjectInitials));
        if isempty(progressInfo)
            progressMsg = '';
        else
            progressMsg = sprintf(' (%d/%d)', progressInfo(1), progressInfo(2));
        end
        regressionStartMsg = strrep(regressionStartMsg, '$PROGRESS$', progressMsg);
        regressionStartMsg = strrep(regressionStartMsg, '$NTP$', num2str(nTimePoints));
        regressionStartMsg = strrep(regressionStartMsg, '$NTRIALS$', num2str(nTrials));
        
        if ~isSilent, fprintf(regressionStartMsg); end
    end

    %-------------------------------------------
    function result = createEmptyRR(predNames, times)
        result = tt.reg.OneRR(expData.SubjectInitials, regressionType, predNames, depVarSpec, times);
        for myVar = predNames
            result.addPredResults(tt.reg.OnePredRR(myVar{1}, length(times)));
        end
    end

    %-------------------------------------------
    % Exclude trials that cannot be regressed (NaN predictor or dependent variable)
    % Fix all variables accordingly
    function [trialsToRegress, predictors, dependentVar, rowNums, includeTrial, nTimePoints] = ...
        removeUnregressableTrials(trialsToRegress, predictors, dependentVar, rowNums, includeTrial)
    
        isOK = findRegressableTrials(predictors, dependentVar);
        
        trialsToRegress = trialsToRegress(isOK);
        predictors = predictors(isOK, :, :);
        dependentVar = dependentVar(isOK, :);
        rowNums = rowNums(isOK, :);
        includeTrial = includeTrial(isOK, :);
        
        %-- Remove time points that exceed trial length
        maxRow = arrayfun(@(t)size(t.Trajectory, 1), trialsToRegress)';
        badTimepoints = arrayfun(@(col)sum(rowNums(:, col) <= maxRow) == 0, 1:size(rowNums, 2));
        rowNums = rowNums(:, ~badTimepoints);
        for i = 1:size(rowNums, 1)
            rowNums(i,:) = min(rowNums(i,:), maxRow(i));
        end
    
        nTimePoints = size(rowNums, 2);
    end



    %-------------------------------------------
    function isOK = findRegressableTrials(predictors, dependentVar)
        
        nanDep = isnan(dependentVar);
        if size(dependentVar, 2) > 1
            nanDep = sum(nanDep, 2); % sum over time points
        end
        
        nanPreds = isnan(predictors);
        nanPreds = sum(nanPreds, 2); % sum over predictors
        if size(predictors, 3) > 1
            nanPreds = sum(nanPreds, 3); % sum over time points
        end
        nanPreds = reshape(nanPreds, numel(nanPreds), 1);
        
        if verbose && sum(nanDep + nanPreds) > 0
            fprintf('Removing %d trials with NaN predictor / dependent variable\n', sum((nanDep + nanPreds) > 0));
        end
        
        isOK = (nanDep + nanPreds) == 0;
        
    end

    %-------------------------------------------
    %-- Get absolute time per time point
    function times = getTimesSameRow(~, trialsToRegress, rowNums)
        [longestTrial, ltInd] = tt.util.getLongestTrial(trialsToRegress);
        times = longestTrial.Trajectory(rowNums(ltInd, :), TrajCols.AbsTime);
        times = times - times(1);
    end

    %-------------------------------------------
    %-- Get absolute time per time point
    function times = getTimesY(~, trialsToRegress, rowNums)
        t = myarrayfun(@(i)trialsToRegress(i).Trajectory(rowNums(i, :), TrajCols.AbsTime), 1:length(trialsToRegress));
        times = nanmean(t, 2)';
    end

    %-------------------------------------------
    % sd_x: [rows x predictors]
    % sd_y: std over trials - one per row
    function calcVariance(result, predictors, dependentVar, nRows)
        
        result.sd_x = reshape(std(predictors), size(predictors, 2), size(predictors, 3))';
        result.sd_y = std(dependentVar)'; 
        
        if fixedDepVar
        	result.sd_y = repmat(result.sd_y, nRows, 1);
        end
        
        if onlyFixedPredictors
            result.sd_x = repmat(result.sd_x, nRows, 1);
        end
    end

    %---------------------------------------------------------------
    % Get data for all predictors, trials, and time points.
    % Data structures differ depending on whether the predictor / dependent
    % variable are per-trial or per-timepoint
    % 
    % Return values:
    % predictors: If at least some predictors are per time point, this is a #trials x #predictors x #TP matrix
    %             If all predictors are pre-trial(fixed), this is a #trials x #predictors matrix
    % dependentVar: either an array (#trials) or a #trials x #TP matrix
    % rowNums: the row number from the trajectory matrix to use for each
    %          trial (a #trials x #timePoints matrix)
    % includeTrial: a #trials x #timePoints matrix indicating whether to include each trial in each timepoint's regression
    %
    function [predictors, predNames, predDesc, dependentVar, dvDesc, rowNums, includeTrial] = ...
            getRegressionData(trialsToRegress, timePoints)
        
        nTP = length(timePoints);
        nTrials = length(trialsToRegress);
        nPredsNoConst = length(predictorSpec);
        
        %-- Convert time points to row numbers.
        %-- "rowNums" is a #trials x #timePoints matrix 
        rowNums = myarrayfun(@(trial)reshape(timePointToRowFunc(timePoints, trial), nTP, 1), trialsToRegress)';
        
        %-- If asked: exclude time points that exceed end of all trials
        if trimTimePointsByTrajEnd
            trialLen = arrayfun(@(trial)trial.NTrajSamples, trialsToRegress)';
            timePointsExceedingAllTrials = arrayfun(@(i)sum(rowNums(:, i) <= trialLen) == 0, 1:nTP);
            rowNums = rowNums(:, ~timePointsExceedingAllTrials);
            nTP = size(rowNums, 2);
        end
        
        %-- Get values for predictors
        if onlyFixedPredictors
            % All predictors are per-trial measures
            [predictors, predNames, predDesc] = getTrialMeasureFunc(expData, trialsToRegress', predictorSpec);
        else
            % At least some predictors are per-timepoint measures
            predictors = NaN(nTrials, nPredsNoConst, nTP);
            predNames = cell(1, nPredsNoConst);
            predDesc = cell(1, nPredsNoConst);
            
            %-- Get values of the per-timepoint predictors
            [prd, pn, pd] = getDynamicMeasureFunc(expData, trialsToRegress', predictorSpec(~fixedPred), rowNums);
            predictors(:, ~fixedPred, :) = prd;
            predNames(~fixedPred) = pn;
            predDesc(~fixedPred) = pd;
            
            %-- Get values of the fixed predictors
            if sum(fixedPred) > 0
                [prd, pn, pd] = getTrialMeasureFunc(expData, trialsToRegress', predictorSpec(fixedPred));
                predNames(fixedPred) = pn;
                predDesc(fixedPred) = pd;
                for iii = 1:length(timePoints) % Copy the same values for all time points
                    predictors(:, fixedPred, iii) = prd;
                end
            end
        end

        %-- Get values for dependent variable
        if fixedDepVar
            [dependentVar, ~, dvDesc] = getTrialMeasureFunc(expData, trialsToRegress', {depVarSpec});
        else
            [dependentVar, ~, dvDesc] = getDynamicMeasureFunc(expData, trialsToRegress', {depVarSpec}, rowNums);
            dependentVar = reshape(dependentVar, size(dependentVar, 1), size(dependentVar, 3));
        end
        
        %-- Apply timepoint-level filters.
        %-- "includeTrial" is a #trials x #timepoints matrix indicating whether to include each trial in each time point
        if isempty(timePointFilters)
            %-- Include all time points
            includeTrial = true(nTrials, nTP);
        else
            %-- Filter out some trials from some timepoints
            includeTrial = myarrayfun(@(i)applyTPFilters(trialsToRegress, timePointFilters, rowNums(:, i))', 1:nTP);
        end
        
        predNames = [{'const'} predNames];
        predDesc = [{'Intercept'} predDesc];
        
    end

    %-------------------------------------------
    % Apply timepoint-level filters:
    % rowNumsPerTrial: vector with one row number per trial
    % Return: vector with one entry (true/false) per trial
    function flags = applyTPFilters(trials, filters, rowNumsPerTrial)
        flags = true(1, length(trials));
        
        for filter = filters
            incl = arrayfun(@(i)filter{1}(trials(i), min(rowNumsPerTrial(i), trials(i).NTrajSamples)), find(flags));
            flags(flags) = logical(incl);
        end
        
        flags = logical(flags);
        
    end

    %-------------------------------------------
    % Update the results of one time point in the global struct
    function result = updateResults(result, oneRR, iRow)
        
        result.RSquare(iRow) = oneRR.rSquare;
        result.p(iRow) = oneRR.regressionPVal;
        result.df = oneRR.df;
        if outputFullStats
            result.stat = [result.stat, {oneRR.stat}];
        end
        if isfield(oneRR, 'MSE')
            result.MSE = oneRR.MSE;
        else
            result.MSE = NaN;
        end

        for iVar = 1:length(predNames)
            predName = predNames{iVar};
            b = oneRR.beta(iVar);
            if strcmp(predName, 'const')
                beta = 0;
            else
                beta = b ./ result.sd_y(iRow) * result.sd_x(iRow, iVar-1);
            end
            predRes = result.getPredResult(predName);
            predRes.b(iRow) = b;
            predRes.beta(iRow) = beta;
            predRes.r2(iRow) = oneRR.r2_per_predictor(iVar);
            predRes.adj_r2(iRow) = oneRR.adj_r2_per_predictor(iVar);
            predRes.p(iRow) = oneRR.p(iVar);
            if strcmp(regressionType, 'reg')
                predRes.se_b(iRow) = oneRR.stderr(iVar);
            end
        end
    end

    %-------------------------------------------------------------------
    % Convert time points from Y coordinates to row numbers
    function rowNums = yToRowNums(y, trial)
        
        trial_y = trial.Trajectory(:, TrajCols.Y);
        mRows = length(trial_y);
        
        rowNums = NaN(1, length(y));
        for i = 1:length(y)
            r = find(trial_y >= y(i), 1);
            rowNums(i) = iif(isempty(r), mRows, r);
        end
        
    end

    %-------------------------------------------------------------------
    function [timePoints, trimRowNumbersByTrajEnd, getTrialsFunc, trialFilters, consolidateTrialsFunc, ...
            timePointFilters, fixedDepVar, saveRegressionInputFilename, ...
            minSamplesToPredictorsRatio, getMeasureFunc, getDynamicMeasureFunc, outputFullStats, ...
            timePointToRowFunc, getTimePerTpFunc, verbose, ...
            regressionStartMsg, printRegressionMsg, isSilent, progressInfo] = parseArgs(args, expData, onlyFixedPredictors, fixedDepVar)

        timePoints = [];
        trimRowNumbersByTrajEnd = true;
        
        dt = [];
        maxTime = NaN;
        getTrialsFunc = @(expData)expData.Trials;
        consolidateTrialsFunc = [];
        trialFilters = {};
        timePointFilters = {};
        getMeasureFunc = @tt.reg.getTrialMeasures;
        getDynamicMeasureFunc = @tt.reg.getTrialDynamicMeasures;
        outputFullStats = false;
        timePointToRowFunc = [];
        getTimePerTpFunc = @getTimesSameRow;
        verbose = false;
        minSamplesToPredictorsRatio = 3;
        is_y = false;
        isSilent = false;
        saveRegressionInputFilename = '';
        
        regressionStartMsg = '';
        printRegressionMsg = true;
        progressInfo = [];
        
        args = stripArgs(args);
        while ~isempty(args)
            switch(lower(args{1}))
                case 'trialfilter'
                    trialFilters = [trialFilters args(2)]; %#ok<*AGROW>
                    args = args(2:end);

                case 'tpfilter'
                    timePointFilters = [timePointFilters args(2)]; %#ok<*AGROW>
                    args = args(2:end);

                case 'dt'
                    dt = args{2};
                    args = args(2:end);
                    
                case 'maxtime'
                    maxTime = args{2};
                    args = args(2:end);
                    
                case 'rows'
                    timePoints = args{2};
                    args = args(2:end);
                    trimRowNumbersByTrajEnd = false;
                    
                case 'fmeasurefunc'
                    getMeasureFunc = args{2};
                    args = args(2:end);
                    
                case 'dmeasurefunc'
                    getDynamicMeasureFunc = args{2};
                    args = args(2:end);
                    
                case 'row1offsetattr'
                    row1OffsetAttrName = args{2};
                    timePointToRowFunc = @(timePoints, trial)timePoints + trial.Custom.(row1OffsetAttrName) - 1;
                    hasRow1AttrValidator = @(trial)isfield(trial.Custom, row1OffsetAttrName) && ~isempty(trial.Custom.(row1OffsetAttrName));
                    trialFilters = [trialFilters {hasRow1AttrValidator}];
                    args = args(2:end);
                    
                case 'row1offsetfunc'
                    offsetFunc = args{2};
                    timePointToRowFunc = @(timePoints, trial)timePoints + offsetFunc(trial) - 1;
                    args = args(2:end);
                    
                case 'tptorowfunc'
                    timePointToRowFunc = args{2};
                    args = args(2:end);
                    
                case 'trialsconsfunc'
                    consolidateTrialsFunc = args{2};
                    args = args(2:end);
                    
                case 'rmessage'
                    regressionStartMsg = args{2};
                    args = args(2:end);
                    if strcmpi(regressionStartMsg, 'silent')
                        printRegressionMsg = false;
                    end
                    
                case 'minspratio'
                    minSamplesToPredictorsRatio = args{2};
                    args = args(2:end);
                    
                case 'tpy'
                    timePointToRowFunc = @yToRowNums;
                    getTimePerTpFunc = @getTimesY;
                    is_y = true;
                    
                case 'saveinput'
                    saveRegressionInputFilename = args{2};
                    args = args(2:end);
                    
                case 'progress'
                    progressInfo = args{2};
                    args = args(2:end);
                    
                case 'avgtrials'
                    getTrialsFunc = @(expData)expData.AvgTrialsAbs;
                    
                case 'tpdep'
                    fixedDepVar = false;
                    
                case 'fullstat'
                    outputFullStats = true;
                    
                case 'v'
                    verbose = true;
                    
                case 'silent'
                    isSilent = true;
                    verbose = false;
                    
                otherwise
                    error('Unsupported argument "%s"!', args{1});
            end
            args = stripArgs(args(2:end));
        end

        %-- Timepoints are meaningless if no regression element is per-timepoint
        if onlyFixedPredictors && fixedDepVar
            timePoints = 1;
            timePointToRowFunc = @(tp,~)tp;
        end
        
        if isempty(timePoints)
            if is_y
                max_y = max(arrayfun(@(t)t.Trajectory(end, TrajCols.Y), expData.Trials));
                dt = iif(isempty(dt), max_y/100, dt);
                timePoints = dt:dt:max_y;
            else
                dt = iif(isempty(dt), 0.05, dt);
                longestTrial = expData.LongestTrial;
                dRow = round(dt / longestTrial.SamplingRate);
                lastTP = iif(isnan(maxTime), longestTrial.NTrajSamples, find(longestTrial.Trajectory(:, TrajCols.AbsTime) >= maxTime-.00001));
                if isempty(lastTP), lastTP = longestTrial.NTrajSamples; end
                timePoints = (dRow+1):dRow:lastTP;
            end
        end
        
        if isempty(timePointToRowFunc)
            timePointToRowFunc = @(tp,~)tp;
        end
        
        timePoints = reshape(timePoints, numel(timePoints), 1);
        
        if ~isempty(timePointFilters) && onlyFixedPredictors && fixedDepVar
            error('Time-point filters ("TPFilter" argument) cannot be used when the dependent variable and all predictors are not per time point');
        end
        
    end

end

