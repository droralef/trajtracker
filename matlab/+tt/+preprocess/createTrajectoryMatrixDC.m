function trajMatrix = createTrajectoryMatrixDC(absTimes, x, y, expData, args)
% trajData = createTrajectoryMatrixDC(absTimes, x, y)
% 
% Create the full trajectory matrix for discrete-choice experiments

    if ~exist('args', 'var')
        args = struct;
    end
    
    [trajMatrix,trajSlope] = tt.preprocess.createTrajectoryMatrixCommonParts(absTimes, x, y, args);

    %-- Implied endpoint, based on dx/dy

    if isfield(args, 'iEPYCoord')
        yMax = args.iEPYCoord;
    else
        maxYPixels = expData.windowHeight() - expData.originCoordY();
        yMax = maxYPixels / expData.PixelsPerUnit;
    end
    yDistanceFromAxis = max(yMax - y, 0); % using max(0) just in case the finger went beyond yMax
    impliedEP = x + (yDistanceFromAxis .* trajSlope);  % on a -1..1 scale

    % The implied endpoint cannot be considered to be outside the iPad screen.
    impliedEP = min(impliedEP, 1);
    impliedEP = max(impliedEP, -1);
    
    trajMatrix(:, TrajCols.ImpliedEP) = impliedEP;
    
end
