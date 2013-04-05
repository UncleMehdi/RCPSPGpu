#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <iostream>
#include <iterator>
#include <fstream>
#include <list>
#include <map>
#include <set>
#include <stdexcept>

#ifdef __GNUC__
#include <sys/time.h>
#elif defined _WIN32 || defined _WIN64 || defined WIN32 || defined WIN64
#include <Windows.h>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#endif

#ifndef UINT32_MAX
#define UINT32_MAX 0xffffffff
#endif
#ifndef USHRT_MAX
#define USHRT_MAX 0xffff
#endif

#include "ConfigureRCPSP.h"
#include "CudaConstants.h"
#include "ScheduleSolver.cuh"
#include "SourcesLoad.h"

using namespace std;

ScheduleSolver::ScheduleSolver(const InputReader& rcpspData, bool verbose) : totalRunTime(0)	{
	// Copy pointers to data of instance.
	instance.numberOfResources = rcpspData.getNumberOfResources();
	instance.capacityOfResources = rcpspData.getCapacityOfResources();
	instance.numberOfActivities = rcpspData.getNumberOfActivities();
	instance.durationOfActivities = rcpspData.getActivitiesDuration();
	instance.numberOfSuccessors = rcpspData.getActivitiesNumberOfSuccessors();
	instance.successorsOfActivity = rcpspData.getActivitiesSuccessors();
	instance.requiredResourcesOfActivities = rcpspData.getActivitiesResources();

	// It measures the start time of the initialisation.
	#ifdef __GNUC__
	timeval startTime, endTime, diffTime;
	gettimeofday(&startTime, NULL);
	#elif defined _WIN32 || defined _WIN64 || defined WIN32 || defined WIN64
	LARGE_INTEGER ticksPerSecond;
	LARGE_INTEGER startTimeStamp, stopTimeStamp;
	QueryPerformanceFrequency(&ticksPerSecond);
	QueryPerformanceCounter(&startTimeStamp);
	#endif
	
	// Create required structures and copy data to GPU.
	initialiseInstanceDataAndInitialSolution(instance, instanceSolution);
	if (prepareCudaMemory(instance, instanceSolution, verbose) == true)	{
		for (uint16_t i = 0; i < instance.numberOfActivities; ++i)	{
			delete[] instance.predecessorsOfActivity[i];
		}
		delete[] instance.predecessorsOfActivity;
		delete[] instance.numberOfPredecessors;
		delete[] instanceSolution.orderOfActivities;
		throw runtime_error("ScheduleSolver::ScheduleSolver: Cuda error detected!");
	}	else	{
		if (verbose == true)
			cout<<"All required resources allocated..."<<endl<<endl;
		instanceSolution.bestScheduleOrder = NULL;
	}

	// It gets the finish time of the initialisation.
	#ifdef __GNUC__
	gettimeofday(&endTime, NULL);
	timersub(&endTime, &startTime, &diffTime);
	totalRunTime += diffTime.tv_sec+diffTime.tv_usec/1000000.;
	#elif defined _WIN32 || defined _WIN64 || defined WIN32 || defined WIN64
	QueryPerformanceCounter(&stopTimeStamp);
	totalRunTime += (stopTimeStamp.QuadPart-startTimeStamp.QuadPart)/((double) ticksPerSecond.QuadPart);
	#endif
}

void ScheduleSolver::initialiseInstanceDataAndInitialSolution(InstanceData& project, InstanceSolution& solution)	{
	// It computes the estimate of the longest duration of the project.
	project.upperBoundMakespan = 0;
	for (uint16_t id = 0; id < project.numberOfActivities; ++id)
		project.upperBoundMakespan += project.durationOfActivities[id];
	
	/* PRECOMPUTE ACTIVITIES PREDECESSORS */

	project.predecessorsOfActivity = new uint16_t*[project.numberOfActivities];
	project.numberOfPredecessors = new uint16_t[project.numberOfActivities];
	memset(project.numberOfPredecessors, 0, sizeof(uint16_t)*project.numberOfActivities);

	for (uint16_t activityId = 0; activityId < project.numberOfActivities; ++activityId)	{
		for (uint16_t successorIdx = 0; successorIdx < project.numberOfSuccessors[activityId]; ++successorIdx)	{
			uint16_t successorId = project.successorsOfActivity[activityId][successorIdx];
			++project.numberOfPredecessors[successorId];
		}
	}

	for (uint16_t activityId = 0; activityId < project.numberOfActivities; ++activityId)	{
		project.predecessorsOfActivity[activityId] = new uint16_t[project.numberOfPredecessors[activityId]];
	}

	for (uint16_t activityId = 0; activityId < project.numberOfActivities; ++activityId)	{
		for (uint16_t successorIdx = 0; successorIdx < project.numberOfSuccessors[activityId]; ++successorIdx)	{
			uint16_t successorId = project.successorsOfActivity[activityId][successorIdx];
			*(project.predecessorsOfActivity[successorId]) = activityId;	
			++project.predecessorsOfActivity[successorId];
		}
	}

	for (uint16_t activityId = 0; activityId < project.numberOfActivities; ++activityId)	{
		project.predecessorsOfActivity[activityId] -= project.numberOfPredecessors[activityId];
	}
	
	/* CREATE INIT ORDER OF ACTIVITIES */

	createInitialSolution(project, solution);
	
	/* PRECOMPUTE MATRIX OF SUCCESSORS */

	project.matrixOfSuccessors = new int8_t*[project.numberOfActivities];
	for (uint16_t i = 0; i < project.numberOfActivities; ++i)	{
		project.matrixOfSuccessors[i] = new int8_t[project.numberOfActivities];
		memset(project.matrixOfSuccessors[i], 0, sizeof(int8_t)*project.numberOfActivities);
	}

	for (uint16_t activityId = 0; activityId < project.numberOfActivities; ++activityId)	{
		for (uint16_t j = 0; j < project.numberOfSuccessors[activityId]; ++j)	{
			project.matrixOfSuccessors[activityId][project.successorsOfActivity[activityId][j]] = 1;
		}
	}
	
	/* IT COMPUTES THE CRITICAL PATH LENGTH */
	uint16_t *lb1 = computeLowerBounds(0, project);
	if (project.numberOfActivities > 1)
		project.criticalPathMakespan = lb1[project.numberOfActivities-1];
	else
		project.criticalPathMakespan = -1;
	delete[] lb1;
	
	/* IT FILLS THE CACHES OF SUCCESSORS/PREDECESSORS */
	for (uint16_t id = 0; id < project.numberOfActivities; ++id)	{
		project.allSuccessorsCache.push_back(getAllActivitySuccessors(id, project));
		project.allPredecessorsCache.push_back(getAllActivityPredecessors(id, project));
	}

	/* THE TRANSFORMED LONGEST PATHS */

	/*
	 * It transformes the instance graph. Directions of edges are changed.
	 * The longest paths are computed from the end dummy activity to the others.
	 * After that the graph is transformed back.
	 */
	changeDirectionOfEdges(project);
	project.rightLeftLongestPaths = computeLowerBounds(project.numberOfActivities-1, project, true);
	changeDirectionOfEdges(project);
	
	/* COMPUTE A MATRIX OF MUTUALLY DISJUNCTIVE ACTIVITIES */

	project.disjunctiveActivities = new bool*[project.numberOfActivities];
	for (uint16_t i = 0; i < project.numberOfActivities; ++i)	{
		project.disjunctiveActivities[i] = new bool[project.numberOfActivities];
		fill(project.disjunctiveActivities[i], project.disjunctiveActivities[i]+project.numberOfActivities, false);
	}

	for (uint16_t i = 0; i < project.numberOfActivities; ++i)	{
		for (uint16_t j = i+1; j < project.numberOfActivities; ++j)	{
			bool simultaneous = true;
			if (binary_search(project.allSuccessorsCache[i]->begin(), project.allSuccessorsCache[i]->end(), j) == true)	{
				simultaneous = false;
			}
			if (simultaneous && binary_search(project.allPredecessorsCache[i]->begin(), project.allPredecessorsCache[i]->end(), j) == true)	{
				simultaneous = false;
			}

			for (uint8_t k = 0; k < project.numberOfResources && simultaneous; ++k)	{
				if (project.requiredResourcesOfActivities[i][k]+project.requiredResourcesOfActivities[j][k] > project.capacityOfResources[k])
					simultaneous = false;
			}

			// Since the matrix is symmetric then matrix[i][j] = matrix[j][i].
			project.disjunctiveActivities[j][i] = project.disjunctiveActivities[i][j] = !simultaneous;
		}
	}	
}

void ScheduleSolver::createInitialSolution(const InstanceData& project, InstanceSolution& solution)	{

	bool anyActivity;
	uint16_t deep = 0;
	uint16_t *levels = new uint16_t[project.numberOfActivities];
	uint8_t *currentLevel = new uint8_t[project.numberOfActivities];
	uint8_t *newCurrentLevel = new uint8_t[project.numberOfActivities];
	memset(levels, 0, sizeof(uint16_t)*project.numberOfActivities);
	memset(currentLevel, 0, sizeof(uint8_t)*project.numberOfActivities);
	solution.orderOfActivities = new uint16_t[project.numberOfActivities];

	// Add first task with id 0. (currentLevel contain ID's)
	currentLevel[0] = 1;

	// The longest paths (the number of edges) are computed and stored in the levels array.
	do {
		anyActivity = false;
		memset(newCurrentLevel, 0, sizeof(uint8_t)*project.numberOfActivities);
		for (uint16_t activityId = 0; activityId < project.numberOfActivities; ++activityId)	{
			if (currentLevel[activityId] == 1)	{
				for (uint16_t nextLevelIdx = 0; nextLevelIdx < project.numberOfSuccessors[activityId]; ++nextLevelIdx)	{
					newCurrentLevel[project.successorsOfActivity[activityId][nextLevelIdx]] = 1;
					anyActivity = true;
				}
				levels[activityId] = deep;
			}
		}

		swap(currentLevel, newCurrentLevel);
		++deep;
	} while (anyActivity == true);

	uint16_t schedIdx = 0;
	for (uint16_t curDeep = 0; curDeep < deep; ++curDeep)	{
		for (uint16_t activityId = 0; activityId < project.numberOfActivities; ++activityId)	{
			if (levels[activityId] == curDeep)
				solution.orderOfActivities[schedIdx++] = activityId;
		}
	}

	delete[] levels;
	delete[] currentLevel;
	delete[] newCurrentLevel;
}

bool ScheduleSolver::prepareCudaMemory(const InstanceData& project, InstanceSolution& solution, bool verbose)	{

	/* PREPARE DATA PHASE */

	/* CONVERT PREDECESSOR AND SUCCESSOR ARRAYS TO 1D */
	uint16_t numOfElPred = 0, numOfElSuc = 0;
	uint16_t *predIdxs = new uint16_t[project.numberOfActivities+1], *sucIdxs = new uint16_t[project.numberOfActivities+1];

	predIdxs[0] = sucIdxs[0] = 0;
	for (uint16_t i = 0; i < project.numberOfActivities; ++i)	{
		numOfElSuc += project.numberOfSuccessors[i];
		numOfElPred += project.numberOfPredecessors[i];
		sucIdxs[i+1] = numOfElSuc;
		predIdxs[i+1] = numOfElPred;
	}

	uint16_t *linSucArray = new uint16_t[numOfElSuc], *linPredArray = new uint16_t[numOfElPred];
	uint16_t *sucWr = linSucArray, *predWr = linPredArray;
	for (uint16_t i = 0; i < project.numberOfActivities; ++i)	{
		for (uint16_t j = 0; j < project.numberOfPredecessors[i]; ++j)
			*(predWr++) = project.predecessorsOfActivity[i][j];
		for (uint16_t j = 0; j < project.numberOfSuccessors[i]; ++j)
			*(sucWr++) = project.successorsOfActivity[i][j];
	}

	/* CONVERT ACTIVITIES RESOURCE REQUIREMENTS TO 1D ARRAY */
	uint32_t resourceReqSize = project.numberOfActivities*project.numberOfResources;
	uint8_t *reqResLin = new uint8_t[resourceReqSize], *resWr = reqResLin;
	for (uint16_t i = 0; i < project.numberOfActivities; ++i)	{
		for (uint8_t r = 0; r < project.numberOfResources; ++r)	{
			*(resWr++) = project.requiredResourcesOfActivities[i][r];
		}
	}

	/* CONVERT CAPACITIES OF RESOURCES TO 1D ARRAY */
	uint16_t *resIdxs = new uint16_t[project.numberOfResources+1];
	resIdxs[0] = 0;
	for (uint8_t r = 0; r < project.numberOfResources; ++r)	{
		resIdxs[r+1] =  resIdxs[r]+project.capacityOfResources[r];
	}

	/* CREATE SUCCESSORS MATRIX */
	uint32_t successorsMatrixSize = project.numberOfActivities*project.numberOfActivities/8;
	if ((project.numberOfActivities*project.numberOfActivities) % 8 != 0)
		++successorsMatrixSize;
	
	uint8_t *successorsMatrix = new uint8_t[successorsMatrixSize];
	memset(successorsMatrix, 0, successorsMatrixSize*sizeof(uint8_t));

	for (uint16_t i = 0; i < project.numberOfActivities; ++i)	{
		for (uint16_t j = 0; j < project.numberOfSuccessors[i]; ++j)	{
			uint16_t activityId = i;
			uint16_t successorId = project.successorsOfActivity[i][j];
			uint32_t bitPossition = activityId*project.numberOfActivities+successorId;
			uint32_t bitIndex = bitPossition % 8;
			uint32_t byteIndex = bitPossition/8;
			successorsMatrix[byteIndex] |= (1<<bitIndex);
		}
	}
	

	/* CUDA INFO + DATA PHASE */

	bool cudaError = false;

	cudaData.numberOfActivities = project.numberOfActivities;
	cudaData.numberOfResources = project.numberOfResources;
	cudaData.maxTabuListSize = ConfigureRCPSP::TABU_LIST_SIZE;
	cudaData.swapRange = ConfigureRCPSP::SWAP_RANGE;
	cudaData.maximalValueOfReadCounter = ConfigureRCPSP::MAXIMAL_VALUE_OF_READ_COUNTER;
	cudaData.numberOfDiversificationSwaps = ConfigureRCPSP::DIVERSIFICATION_SWAPS;
	cudaData.criticalPathLength = project.criticalPathMakespan;
	cudaData.sumOfCapacities = 0;
	for (uint8_t i = 0; i < project.numberOfResources; ++i)
		cudaData.sumOfCapacities += project.capacityOfResources[i];
	cudaData.maximalCapacityOfResource = *max_element(project.capacityOfResources, project.capacityOfResources+project.numberOfResources);

	/* GET CUDA INFO - SET NUMBER OF THREADS PER BLOCK */

	int devId = 0;
	cudaDeviceProp prop;
	memset(&prop, 0, sizeof(cudaDeviceProp));
	prop.major = 2; prop.minor = 0;

	if (cudaChooseDevice(&devId, &prop) == cudaSuccess && cudaGetDeviceProperties(&prop, devId) == cudaSuccess && cudaSetDevice(devId) == cudaSuccess)	{
		if (verbose == true)	{
			cout<<"Device number: "<<devId<<endl;
			cout<<"Device name: "<<prop.name<<endl;
			cout<<"Device compute capability: "<<prop.major<<"."<<prop.minor<<endl;
			cout<<"Number of multiprocessors: "<<prop.multiProcessorCount<<endl;
			cout<<"Clock rate: "<<prop.clockRate/1000<<" MHz"<<endl;
			cout<<"Size of constant memory: "<<prop.totalConstMem<<" B"<<endl;
			cout<<"Size of shared memory per multiprocessor: "<<prop.sharedMemPerBlock<<" B"<<endl;
			cout<<"Size of global memory: "<<prop.totalGlobalMem<<" B"<<endl;
			cout<<"Number of 32-bit registers per multiprocessor: "<<prop.regsPerBlock<<endl<<endl;
		}

		cudaCapability = prop.major*100+prop.minor*10;
		numberOfBlock = prop.multiProcessorCount*ConfigureRCPSP::NUMBER_OF_BLOCKS_PER_MULTIPROCESSOR;

		if (cudaCapability < 300)
			numberOfThreadsPerBlock = 512;
		else
			numberOfThreadsPerBlock = 1024;

		if (cudaCapability < 200)	{
			cerr<<"Pre-Fermi cards aren't supported! Sorry..."<<endl;
			cudaError = true;
		}
	} else {
		cudaError = errorHandler(-2);
	}

	/* EVALUTATION ALGORITHM SELECTION */

	if (project.numberOfActivities < 100)	{
		cudaData.capacityResolutionAlgorithm = false;
	} else if (project.numberOfActivities >= 100 && project.numberOfActivities < 140)	{
		// It computes required parameters.
		uint32_t sumOfCapacities = cudaData.sumOfCapacities, sumOfSuccessors = 0;
		uint8_t minimalResourceCapacity, maximalResourceCapacity = cudaData.maximalCapacityOfResource;
		for (uint16_t i = 0; i < project.numberOfActivities; ++i)
			sumOfSuccessors += project.numberOfSuccessors[i];
		minimalResourceCapacity = *min_element(project.capacityOfResources, project.capacityOfResources+project.numberOfResources);
		double branchFactor = (((double) sumOfSuccessors)/((double) project.numberOfActivities));
		// Decision what evaluation algorithm should be used.
		if (minimalResourceCapacity >= 29)
			cudaData.capacityResolutionAlgorithm = false;
		else if (sumOfCapacities >= 116 && branchFactor > 2.106)
			cudaData.capacityResolutionAlgorithm = false;
		else if (minimalResourceCapacity >= 25 && maximalResourceCapacity >= 42)
			cudaData.capacityResolutionAlgorithm = false;
		else
			cudaData.capacityResolutionAlgorithm = true;
	} else {
		cudaData.capacityResolutionAlgorithm = true;
	}


	/* COPY ACTIVITIES DURATION TO CUDA */
	if (!cudaError && cudaMalloc((void**) &cudaData.durationOfActivities, project.numberOfActivities*sizeof(uint8_t)) != cudaSuccess)	{
		cudaError = errorHandler(-2);
	}
	if (!cudaError && cudaMemcpy(cudaData.durationOfActivities, project.durationOfActivities, project.numberOfActivities*sizeof(uint8_t), cudaMemcpyHostToDevice) != cudaSuccess)	{
		cudaError = errorHandler(0);
	} 

	/* COPY PREDECESSORS+INDICES TO CUDA TEXTURE MEMORY */
	if (!cudaError && cudaMalloc((void**) &cudaPredecessorsArray, numOfElPred*sizeof(uint16_t)) != cudaSuccess)	{
		cudaError = errorHandler(0);
	}
	if (!cudaError && cudaMemcpy(cudaPredecessorsArray, linPredArray, numOfElPred*sizeof(uint16_t), cudaMemcpyHostToDevice) != cudaSuccess)	{
		cudaError = errorHandler(1);
	}
	if (!cudaError && bindTexture(cudaPredecessorsArray, numOfElPred, PREDECESSORS) != cudaSuccess)	{
		cudaError = errorHandler(1);
	}
	if (!cudaError && cudaMalloc((void**) &cudaPredecessorsIdxsArray, (project.numberOfActivities+1)*sizeof(uint16_t)) != cudaSuccess)	{
		cudaError = errorHandler(2);
	}
	if (!cudaError && cudaMemcpy(cudaPredecessorsIdxsArray, predIdxs, (project.numberOfActivities+1)*sizeof(uint16_t), cudaMemcpyHostToDevice) != cudaSuccess)	{
		cudaError = errorHandler(3);
	}
	if (!cudaError && bindTexture(cudaPredecessorsIdxsArray, project.numberOfActivities+1, PREDECESSORS_INDICES) != cudaSuccess)	{
		cudaError = errorHandler(3);
	} 

	/* COPY SUCCESSORS BIT MATRIX */
	if (!cudaError && cudaMalloc((void**) &cudaData.successorsMatrix, successorsMatrixSize*sizeof(uint8_t)) != cudaSuccess)	{
		cudaError = errorHandler(4);
	}
	if (!cudaError && cudaMemcpy(cudaData.successorsMatrix, successorsMatrix, successorsMatrixSize*sizeof(uint8_t), cudaMemcpyHostToDevice) != cudaSuccess)	{
		cudaError = errorHandler(5);
	} 

	/* COPY ACTIVITIES RESOURCE REQUIREMENTS TO TEXTURE MEMORY */
	if (!cudaError && cudaMalloc((void**) &cudaActivitiesResourcesArray, resourceReqSize*sizeof(uint8_t)) != cudaSuccess)	{
		cudaError = errorHandler(5);
	}
	if (!cudaError && cudaMemcpy(cudaActivitiesResourcesArray, reqResLin, resourceReqSize*sizeof(uint8_t), cudaMemcpyHostToDevice)	!= cudaSuccess)	{
		cudaError = errorHandler(6);
	}
	if (!cudaError && bindTexture(cudaActivitiesResourcesArray, resourceReqSize, ACTIVITIES_RESOURCES) != cudaSuccess)	{
		cudaError = errorHandler(6);
	}

	/* COPY RESOURCES CAPACITIES TO CUDA MEMORY */
	if (!cudaError && cudaMalloc((void**) &cudaData.resourceIndices, (project.numberOfResources+1)*sizeof(uint16_t)) != cudaSuccess)	{
		cudaError = errorHandler(7);
	}
	if (!cudaError && cudaMemcpy(cudaData.resourceIndices, resIdxs, (project.numberOfResources+1)*sizeof(uint16_t), cudaMemcpyHostToDevice) != cudaSuccess)	{
		cudaError = errorHandler(8);
	}

	/* COPY TABU LISTS TO CUDA MEMORY */
	if (!cudaError && cudaMalloc((void**) &cudaData.tabuLists, numberOfBlock*cudaData.maxTabuListSize*sizeof(MoveIndices)) != cudaSuccess)	{
		cudaError = errorHandler(8);
	}
	if (!cudaError && cudaMemset(cudaData.tabuLists, 0, numberOfBlock*cudaData.maxTabuListSize*sizeof(MoveIndices)) != cudaSuccess)	{
		cudaError = errorHandler(9);
	}

	/* CREATE TABU CACHE */
	if (!cudaError && cudaMalloc((void**) &cudaData.tabuCaches, project.numberOfActivities*project.numberOfActivities*numberOfBlock*sizeof(uint8_t)) != cudaSuccess)	{
		cudaError = errorHandler(9);
	}
	if (!cudaError && cudaMemset(cudaData.tabuCaches, 0, project.numberOfActivities*project.numberOfActivities*numberOfBlock*sizeof(uint8_t)) != cudaSuccess)	{
		cudaError = errorHandler(10);
	}

	/* COPY INITIAL SET SOLUTIONS */
	if (!cudaError)
		cudaError = loadInitialSolutionsToGpu(ConfigureRCPSP::NUMBER_OF_SET_SOLUTIONS);

	/* BEST CURRENT SOLUTIONS OF THE BLOCKS */
	if (!cudaError && cudaMalloc((void**) &cudaData.blocksBestSolution, project.numberOfActivities*numberOfBlock*sizeof(uint16_t)) != cudaSuccess)	{
		cudaError = errorHandler(17);
	}

	/* CREATE SWAP PENALTY FREE MERGE ARRAYS */
	if (!cudaError && cudaMalloc((void**) &cudaData.swapMergeArray, (project.numberOfActivities-2)*cudaData.swapRange*numberOfBlock*sizeof(MoveIndices)) != cudaSuccess)	{
		cudaError = errorHandler(18);
	}
	if (!cudaError && cudaMalloc((void**) &cudaData.mergeHelpArray, (project.numberOfActivities-2)*cudaData.swapRange*numberOfBlock*sizeof(MoveIndices)) != cudaSuccess)	{
		cudaError = errorHandler(19);
	}

	/* CREATE COUNTER TO COUNT NUMBER OF EVALUATED SCHEDULES */
	if (!cudaError && cudaMalloc((void**) &cudaData.evaluatedSchedules, sizeof(uint64_t)) != cudaSuccess)	{
		cudaError = errorHandler(20);
	}
	if (!cudaError && cudaMemset(cudaData.evaluatedSchedules, 0, sizeof(uint64_t)) != cudaSuccess)	{
		cudaError = errorHandler(21);
	}

	/* COPY SUCCESSORS+INDICES TO CUDA TEXTURE MEMORY */
	if (!cudaError && cudaMalloc((void**) &cudaSuccessorsArray, numOfElSuc*sizeof(uint16_t)) != cudaSuccess)	{
		cudaError = errorHandler(21);
	}
	if (!cudaError && cudaMemcpy(cudaSuccessorsArray, linSucArray, numOfElSuc*sizeof(uint16_t), cudaMemcpyHostToDevice) != cudaSuccess)	{
		cudaError = errorHandler(22);
	}
	if (!cudaError && bindTexture(cudaSuccessorsArray, numOfElSuc, SUCCESSORS) != cudaSuccess)	{
		cudaError = errorHandler(22);
	}
	if (!cudaError && cudaMalloc((void**) &cudaSuccessorsIdxsArray, (project.numberOfActivities+1)*sizeof(uint16_t)) != cudaSuccess)	{
		cudaError = errorHandler(23);
	}
	if (!cudaError && cudaMemcpy(cudaSuccessorsIdxsArray, sucIdxs, (project.numberOfActivities+1)*sizeof(uint16_t), cudaMemcpyHostToDevice) != cudaSuccess)	{
		cudaError = errorHandler(24);
	}
	if (!cudaError && bindTexture(cudaSuccessorsIdxsArray, project.numberOfActivities+1, SUCCESSORS_INDICES) != cudaSuccess)	{
		cudaError = errorHandler(24);
	}
	
	/* COPY THE LONGEST PATH TO THE CONSTANT MEMORY */
	if (!cudaError && memcpyToSymbol((void*) project.rightLeftLongestPaths, project.numberOfActivities, THE_LONGEST_PATHS) != cudaSuccess)	{
		cudaError = errorHandler(25);
	}


	/* COMPUTE DYNAMIC MEMORY REQUIREMENT */

	dynSharedMemSize = numberOfThreadsPerBlock*sizeof(MoveInfo);	// merge array
	dynSharedMemSize += numberOfBlock*cudaData.numberOfAddedEdges*sizeof(Edge);	// added edges for each block
	
	if ((project.numberOfActivities-2)*cudaData.swapRange < USHRT_MAX)
		dynSharedMemSize += numberOfThreadsPerBlock*sizeof(uint16_t); // merge help array
	else
		dynSharedMemSize += numberOfThreadsPerBlock*sizeof(uint32_t); // merge help array

	dynSharedMemSize += project.numberOfActivities*sizeof(uint16_t);	// block order
	dynSharedMemSize += (project.numberOfResources+1)*sizeof(uint16_t);	// resources indices
	dynSharedMemSize += project.numberOfActivities*sizeof(uint8_t);		// duration of activities

	// If it is possible to run 2 block (shared memory restrictions) then copy successorsMatrix to shared memory.
	if (dynSharedMemSize+successorsMatrixSize*sizeof(uint8_t) < 7950)	{
		dynSharedMemSize += successorsMatrixSize*sizeof(uint8_t);
		cudaData.copySuccessorsMatrixToSharedMemory = true;
	} else	{
		cudaData.copySuccessorsMatrixToSharedMemory = false;
	}
	cudaData.successorsMatrixSize = successorsMatrixSize;

	// Print info...
	if (verbose == true)	{
		cout<<"Dynamic shared memory requirement: "<<dynSharedMemSize<<" B"<<endl;
		cout<<"Number of threads per block: "<<numberOfThreadsPerBlock<<endl<<endl;
	}

	/* FREE ALLOCATED TEMPORARY RESOURCES */
	delete[] successorsMatrix;
	delete[] resIdxs;
	delete[] reqResLin;
	delete[] linSucArray;
	delete[] linPredArray;
	delete[] sucIdxs;
	delete[] predIdxs;

	return cudaError;
}

bool ScheduleSolver::loadInitialSolutionsToGpu(const uint16_t& numberOfSetSolutions)	{

	bool cudaError = false;
	// Generate all disjunctive activity pairs, i.e. both activities in a pair cannot run concurrently.
	vector<pair<uint16_t, uint16_t> > candidates;
	for (uint16_t i = 0; i < instance.numberOfActivities; ++i)	{
		for (uint16_t j = 0; j < instance.numberOfActivities; ++j)	{
			if (instance.disjunctiveActivities[i][j] == true)	{
				if (binary_search(instance.allSuccessorsCache[i]->begin(), instance.allSuccessorsCache[i]->end(), j) == true)
					continue;
				if (binary_search(instance.allPredecessorsCache[i]->begin(), instance.allPredecessorsCache[i]->end(), j) == true)
					continue;
				candidates.push_back(pair<uint16_t, uint16_t>(i,j));
			}
		}
	}

	srand(time(NULL));
	uint32_t numberOfEdges = 0;
	list<InstanceData> staticTree;
	staticTree.push_back(instance);
	vector<pair<uint8_t,void*> > allocatedMemory;

	while (staticTree.size() < numberOfSetSolutions && !staticTree.empty())	{
		InstanceData parent = staticTree.front();
		uint16_t parentLowerBound = lowerBoundOfMakespan(parent);
		staticTree.pop_front();

		bool threadsStop = false;
		InstanceData bestChild1, bestChild2;
		uint32_t bestBranchCost = UINT32_MAX;
		random_shuffle(candidates.begin(), candidates.end());
		// Try each candidate (a pair of disjunctive activities) and select the best one.
		#pragma omp parallel for 
		for (uint32_t o = 0; o < candidates.size(); ++o)	{
			if (!threadsStop)	{
				// Selected pair of activities.
				InstanceData child1 = parent, child2 = parent;
				uint16_t i = candidates[o].first, j = candidates[o].second;

				// Check if there is no path between both candidate activities.
				bool alreadyAdded = false;
				for (vector<Edge>::const_iterator it = parent.addedEdges.begin(); it != parent.addedEdges.end(); ++it)	{
					if ((it->i == i && it->j == j) || (it->i == j && it->j == i)
							|| (binary_search(parent.allSuccessorsCache[i]->begin(), parent.allSuccessorsCache[i]->end(), j) == true)
							|| (binary_search(parent.allPredecessorsCache[i]->begin(), parent.allPredecessorsCache[i]->end(), j) == true))	{
						alreadyAdded = true;
						break;	
					}
				}

				if (alreadyAdded)
					continue;

				// Create two leaf-nodes for both added edges.
				for (uint8_t s = 0; s < 2; ++s)	{
					// Select edge (i,j) or (j,i).
					InstanceData& child = (s == 0 ? child1 : child2);
					// Alloc and copy required memory, e.g. successors and predecessors 2D arrays, the number of them...
					uint16_t *numberOfSuccessors = new uint16_t[parent.numberOfActivities], *numberOfPredecessors = new uint16_t[parent.numberOfActivities];
					uint16_t **copySuccessors = new uint16_t*[parent.numberOfActivities], **copyPredecessors = new uint16_t*[parent.numberOfActivities];
					copy(parent.successorsOfActivity, parent.successorsOfActivity+parent.numberOfActivities, copySuccessors);
					copy(parent.predecessorsOfActivity, parent.predecessorsOfActivity+parent.numberOfActivities, copyPredecessors);
					copy(parent.numberOfSuccessors, parent.numberOfSuccessors+parent.numberOfActivities, numberOfSuccessors);
					copy(parent.numberOfPredecessors, parent.numberOfPredecessors+parent.numberOfActivities, numberOfPredecessors);
					child.numberOfSuccessors = numberOfSuccessors; child.numberOfPredecessors = numberOfPredecessors;
					child.successorsOfActivity = copySuccessors; child.predecessorsOfActivity = copyPredecessors;
					// Add edge (i,j) or (j,i).
					copySuccessors[i] = copyAndPush(parent.successorsOfActivity[i], numberOfSuccessors[i], j);
					copyPredecessors[j] = copyAndPush(parent.predecessorsOfActivity[j], numberOfPredecessors[j], i);
					++numberOfSuccessors[i]; ++numberOfPredecessors[j];
					// Update the caches of successors and predecessors;
					vector<uint16_t>* iPart = new vector<uint16_t>(*parent.allPredecessorsCache[i]);
					vector<uint16_t>* jPart = new vector<uint16_t>(*parent.allSuccessorsCache[j]);
					vector<uint16_t>::iterator sit1 = upper_bound(iPart->begin(), iPart->end(), i);
					vector<uint16_t>::iterator sit2 = upper_bound(jPart->begin(), jPart->end(), j);
					iPart->insert(sit1, i); jPart->insert(sit2, j);
					for (uint8_t f = 0; f < 2; ++f)	{
						vector<vector<uint16_t>*>& cache = (f == 0 ? parent.allSuccessorsCache : parent.allPredecessorsCache);
						vector<vector<uint16_t>*>& childCache = (f == 0 ? child.allSuccessorsCache : child.allPredecessorsCache);
						for (vector<uint16_t>::const_iterator it2 = iPart->begin(); it2 != iPart->end(); ++it2)	{
							vector<uint16_t> *result = new vector<uint16_t>();
							back_insert_iterator<vector<uint16_t> > bit(*result);
							set_union(cache[*it2]->begin(), cache[*it2]->end(), jPart->begin(), jPart->end(), bit);
							childCache[*it2] = result;
							#pragma omp critical
							allocatedMemory.push_back(pair<uint8_t,void*>(2, result));
						}
						swap(iPart, jPart);
					}
					delete iPart; delete jPart;
					// Update the matrix of disjunctive activities.
					bool *allocatedRows = new bool[parent.numberOfActivities];
					fill(allocatedRows, allocatedRows+parent.numberOfActivities, false);
					child.disjunctiveActivities = new bool*[parent.numberOfActivities];
					copy(parent.disjunctiveActivities, parent.disjunctiveActivities+parent.numberOfActivities, child.disjunctiveActivities);
					#pragma omp critical
					allocatedMemory.push_back(pair<uint8_t,void*>(3, child.disjunctiveActivities));
					for (uint16_t a = 0; a < parent.numberOfActivities; ++a)	{
						for (uint8_t l = 0; l < 2; ++l)	{
							uint16_t c = (l == 0 ? i : j);
							if (a != c && parent.disjunctiveActivities[c][a] == false)	{
								if ((binary_search(child.allSuccessorsCache[c]->begin(), child.allSuccessorsCache[c]->end(), a) == true)
										|| (binary_search(child.allPredecessorsCache[c]->begin(), child.allPredecessorsCache[c]->end(), a) == true))	{
									if (!allocatedRows[a])	{
										child.disjunctiveActivities[a] = new bool[parent.numberOfActivities];
										copy(parent.disjunctiveActivities[a], parent.disjunctiveActivities[a]+parent.numberOfActivities, child.disjunctiveActivities[a]);
										allocatedRows[a] = true;
										#pragma omp critical
										allocatedMemory.push_back(pair<uint8_t,void*>(4, child.disjunctiveActivities[a]));
									}
									if (!allocatedRows[c])	{
										child.disjunctiveActivities[c] = new bool[parent.numberOfActivities];
										copy(parent.disjunctiveActivities[c], parent.disjunctiveActivities[c]+parent.numberOfActivities, child.disjunctiveActivities[c]);
										allocatedRows[c] = true;
										#pragma omp critical
										allocatedMemory.push_back(pair<uint8_t,void*>(4, child.disjunctiveActivities[c]));
									}
									child.disjunctiveActivities[a][c] = child.disjunctiveActivities[c][a] = true;
								}
							}
						}
					}
					delete[] allocatedRows;
					// Store all pointers to the allocated memory to be able to free it later.
					#pragma omp critical
					{
						allocatedMemory.push_back(pair<uint8_t,void*>(0, child.successorsOfActivity[i]));
						allocatedMemory.push_back(pair<uint8_t,void*>(0, child.predecessorsOfActivity[j]));
						allocatedMemory.push_back(pair<uint8_t,void*>(1, copySuccessors));
						allocatedMemory.push_back(pair<uint8_t,void*>(1, copyPredecessors));
						allocatedMemory.push_back(pair<uint8_t,void*>(0, numberOfSuccessors));
						allocatedMemory.push_back(pair<uint8_t,void*>(0, numberOfPredecessors));
					}
					// Swap direction of the edge.
					swap(i,j);
				}

				uint16_t lb1 = lowerBoundOfMakespan(child1);
				uint16_t lb2 = lowerBoundOfMakespan(child2);
				if (lb1 + lb2 <= 2*parentLowerBound)	{
					#pragma omp critical
					threadsStop = true;
				}
				#pragma omp critical
				{
				if (lb1 + lb2 < bestBranchCost)	{
					bestBranchCost = lb1+lb2;
					bestChild1 = child1; bestChild2 = child2;
					Edge edge1 = { i,j, instance.durationOfActivities[i] };
					Edge edge2 = { j,i, instance.durationOfActivities[j] };
					bestChild1.addedEdges.push_back(edge1);
					bestChild2.addedEdges.push_back(edge2);
				}
				}
			}
		}

		if (bestBranchCost < UINT32_MAX)	{
			numberOfEdges = max((size_t) numberOfEdges, max(bestChild1.addedEdges.size(), bestChild2.addedEdges.size()));
			staticTree.push_back(bestChild1);
			staticTree.push_back(bestChild2);
		}
	}

	// Convert tree leaf-nodes to GPU solutions.
	bool solutionsExtractedFromStaticTree = false;
	uint32_t bestScheduleLength = UINT32_MAX, indexToBestSchedule = 0;
	Edge *addedEdges = new Edge[numberOfSetSolutions*numberOfEdges];
	SolutionInfo *infoAboutSolutions = new SolutionInfo[numberOfSetSolutions];
	uint16_t *solutions = new uint16_t[numberOfSetSolutions*instance.numberOfActivities], *solutionsPtr = solutions;
	if (staticTree.size() == numberOfSetSolutions)	{
		solutionsExtractedFromStaticTree = true;
		uint32_t infoWriterIdx = 0, edgeWriterIdx = 0;
		for (list<InstanceData>::const_iterator it = staticTree.begin(); it != staticTree.end(); ++it)	{
			InstanceSolution nodeSolution;
			createInitialSolution(*it, nodeSolution);
			uint32_t scheduleLength = shakingDownEvaluation(*it, nodeSolution, solutionsPtr);
			convertStartTimesById2ActivitiesOrder(*it, nodeSolution, solutionsPtr);
			if (scheduleLength < bestScheduleLength)	{
				bestScheduleLength = scheduleLength;
				indexToBestSchedule = infoWriterIdx;
			}
			infoAboutSolutions[infoWriterIdx].solutionCost = scheduleLength;
			infoAboutSolutions[infoWriterIdx].readCounter = infoAboutSolutions[infoWriterIdx].iterationCounter = 0;
			solutionsPtr = copy(nodeSolution.orderOfActivities, nodeSolution.orderOfActivities+it->numberOfActivities, solutionsPtr);
			delete[] nodeSolution.orderOfActivities; ++infoWriterIdx;
			for (uint32_t i = 0; i < numberOfEdges; ++i)    {
				if (i < it->addedEdges.size())	{
					addedEdges[edgeWriterIdx++] = it->addedEdges[i];
				} else {
					 Edge zeroEdge = { 0, 0, 0 };
					 addedEdges[edgeWriterIdx++] = zeroEdge;
				}
			}
		}
	} else {
		// Not sufficient number of solutions was created. It creates all solutions using diversification.
		for (uint32_t solutionIdx = 0; solutionIdx < numberOfSetSolutions; ++solutionIdx)	{
			uint32_t scheduleLength = 0;
			if ((solutionIdx % 2) == 0)	{
				scheduleLength = forwardScheduleEvaluation(instance, instanceSolution, solutionsPtr);
			} else {
				scheduleLength = shakingDownEvaluation(instance, instanceSolution, solutionsPtr);
				convertStartTimesById2ActivitiesOrder(instance, instanceSolution, solutionsPtr);
			}
			if (scheduleLength < bestScheduleLength)	{
				bestScheduleLength = scheduleLength;
				indexToBestSchedule = solutionIdx;
			}
			infoAboutSolutions[solutionIdx].solutionCost = scheduleLength;
			infoAboutSolutions[solutionIdx].readCounter = infoAboutSolutions[solutionIdx].iterationCounter = 0;
			solutionsPtr = copy(instanceSolution.orderOfActivities, instanceSolution.orderOfActivities+instance.numberOfActivities, solutionsPtr);
			makeDiversification(instance, instanceSolution);
		}
		memset(addedEdges, 0, numberOfSetSolutions*numberOfEdges*sizeof(Edge));
	}

	// Copy solutions to GPU memory.
	cudaData.totalSolutions = numberOfSetSolutions;
	cudaData.numberOfAddedEdges = (solutionsExtractedFromStaticTree ? numberOfEdges : 0);
	
	/* COPY INITIAL SOLUTIONS TO THE SOLUTION SET */
	if (!cudaError && cudaMalloc((void**) &cudaData.infoAboutSolutions, numberOfSetSolutions*sizeof(SolutionInfo)) != cudaSuccess)	{
		cudaError = errorHandler(10);
	}
	if (!cudaError && cudaMemcpy(cudaData.infoAboutSolutions, infoAboutSolutions, numberOfSetSolutions*sizeof(SolutionInfo), cudaMemcpyHostToDevice) != cudaSuccess)	{
		cudaError = errorHandler(11);
	}
	if (!cudaError && cudaMalloc((void**) &cudaData.ordersOfSolutions, numberOfSetSolutions*instance.numberOfActivities*sizeof(uint16_t)) != cudaSuccess)	{
		cudaError = errorHandler(11);
	}
	if (!cudaError && cudaMemcpy(cudaData.ordersOfSolutions, solutions, numberOfSetSolutions*instance.numberOfActivities*sizeof(uint16_t), cudaMemcpyHostToDevice) != cudaSuccess)	{
		cudaError = errorHandler(12);
	}
	if (!cudaError && cudaMalloc((void**) &cudaData.addedEdges, numberOfSetSolutions*numberOfEdges*sizeof(Edge)) != cudaSuccess)	{
		cudaError = errorHandler(12);
	}
	if (!cudaError && cudaMemcpy(cudaData.addedEdges, addedEdges, numberOfSetSolutions*numberOfEdges*sizeof(Edge), cudaMemcpyHostToDevice) != cudaSuccess)	{
		cudaError = errorHandler(13);
	}

	/* CREATE TABU LISTS OF THE SOLUTION SET */
	if (!cudaError && cudaMalloc((void**) &cudaData.tabuListsOfSetOfSolutions, numberOfSetSolutions*cudaData.maxTabuListSize*sizeof(MoveIndices)) != cudaSuccess)	{
		cudaError = errorHandler(13);
	}
	if (!cudaError && cudaMemset(cudaData.tabuListsOfSetOfSolutions, 0,  numberOfSetSolutions*cudaData.maxTabuListSize*sizeof(MoveIndices)) != cudaSuccess)	{
		cudaError = errorHandler(14);
	}

	/* CREATE ACCESS LOCK OF THE SOLUTION SET */
	if (!cudaError && cudaMalloc((void**) &cudaData.lockSetOfSolutions, sizeof(uint32_t)) != cudaSuccess)	{
		cudaError = errorHandler(14);
	}
	if (!cudaError && cudaMemset(cudaData.lockSetOfSolutions, DATA_AVAILABLE, sizeof(uint32_t)) != cudaSuccess)	{
		cudaError = errorHandler(15);
	}

	/* GLOBAL BEST SOLUTION INFO */
	if (!cudaError && cudaMalloc((void**) &cudaData.bestSolutionCost, sizeof(uint32_t)) != cudaSuccess)	{
		cudaError = errorHandler(15);
	}
	if (!cudaError && cudaMemcpy(cudaData.bestSolutionCost, &bestScheduleLength, sizeof(uint32_t), cudaMemcpyHostToDevice) != cudaSuccess)	{
		cudaError = errorHandler(16);
	}
	if (!cudaError && cudaMalloc((void**) &cudaData.indexToTheBestSolution, sizeof(uint32_t)) != cudaSuccess)	{
		cudaError = errorHandler(16);
	}
	if (!cudaError && cudaMemcpy(cudaData.indexToTheBestSolution, &indexToBestSchedule, sizeof(uint32_t), cudaMemcpyHostToDevice) != cudaSuccess)	{
		cudaError = errorHandler(17);
	}
	
	delete[] solutions;
	delete[] infoAboutSolutions;
	delete[] addedEdges;

	// Free dynamically allocated memory.
	for (vector<pair<uint8_t,void*> >::iterator it = allocatedMemory.begin(); it != allocatedMemory.end(); ++it)	{
		switch (it->first)	{
			case 0:
				delete[] (uint16_t*) it->second;
				break;
			case 1:
				delete[] (uint16_t**) it->second;
				break;
			case 2:
				delete (vector<uint16_t>*) it->second;
				break;
			case 3:
				delete[] (bool**) it->second;
				break;
			case 4:
				delete[] (bool*) it->second;
				break;
		}
	}

	return cudaError;
}

bool ScheduleSolver::errorHandler(int16_t phase)	{
	if (phase != -1)
		cerr<<"Cuda error: "<<cudaGetErrorString(cudaGetLastError())<<endl;

	switch (phase)	{
		case -1:
		case 25:
			unbindTexture(SUCCESSORS_INDICES);
		case 24:
			cudaFree(cudaSuccessorsIdxsArray);
		case 23:
			unbindTexture(SUCCESSORS);
		case 22:
			cudaFree(cudaSuccessorsArray);
		case 21:
			cudaFree(cudaData.evaluatedSchedules);
		case 20:
			cudaFree(cudaData.mergeHelpArray);
		case 19:
			cudaFree(cudaData.swapMergeArray);
		case 18:
			cudaFree(cudaData.blocksBestSolution);
		case 17:
			cudaFree(cudaData.indexToTheBestSolution);
		case 16:
			cudaFree(cudaData.bestSolutionCost);
		case 15:
			cudaFree(cudaData.lockSetOfSolutions);
		case 14:
			cudaFree(cudaData.tabuListsOfSetOfSolutions);
		case 13:
			cudaFree(cudaData.addedEdges);
		case 12:
			cudaFree(cudaData.ordersOfSolutions);
		case 11:
			cudaFree(cudaData.infoAboutSolutions);
		case 10:
			cudaFree(cudaData.tabuCaches);
		case 9:
			cudaFree(cudaData.tabuLists);
		case 8:
			cudaFree(cudaData.resourceIndices);
		case 7:
			unbindTexture(ACTIVITIES_RESOURCES);
		case 6:
			cudaFree(cudaActivitiesResourcesArray);
		case 5:
			cudaFree(cudaData.successorsMatrix);
		case 4:
			unbindTexture(PREDECESSORS_INDICES);
		case 3:
			cudaFree(cudaPredecessorsIdxsArray);
		case 2:
			unbindTexture(PREDECESSORS);
		case 1:
			cudaFree(cudaPredecessorsArray);
		case 0:
			cudaFree(cudaData.durationOfActivities);

		default:
			break;
	} 
	return true;
}

void ScheduleSolver::solveSchedule(const uint32_t& maxIter, const uint32_t& maxIterSinceBest)	{
	#ifdef __GNUC__
	timeval startTime, endTime, diffTime;
	gettimeofday(&startTime, NULL);
	#elif defined _WIN32 || defined _WIN64 || defined WIN32 || defined WIN64
	LARGE_INTEGER ticksPerSecond;
	LARGE_INTEGER startTimeStamp, stopTimeStamp;
	QueryPerformanceFrequency(&ticksPerSecond);
	QueryPerformanceCounter(&startTimeStamp);
	#endif

	// Set iterations parameters.
	cudaData.numberOfIterationsPerBlock = maxIter;
	cudaData.maximalIterationsSinceBest = maxIterSinceBest;

	/* RUN CUDA RCPSP SOLVER */

	runCudaSolveRCPSP(numberOfBlock, numberOfThreadsPerBlock, cudaCapability, dynSharedMemSize, cudaData);

	/* GET BEST FOUND SOLUTION */

	bool cudaError = false;
	uint32_t indexToTheBestSolution;
	instanceSolution.bestScheduleOrder = new uint16_t[instance.numberOfActivities];
	if (!cudaError && cudaMemcpy(&instanceSolution.costOfBestSchedule, cudaData.bestSolutionCost, sizeof(uint32_t), cudaMemcpyDeviceToHost) != cudaSuccess)	{
		cudaError = true;	
	}
	if (!cudaError && cudaMemcpy(&indexToTheBestSolution, cudaData.indexToTheBestSolution, sizeof(uint32_t), cudaMemcpyDeviceToHost) != cudaSuccess)	{
		cudaError = true;
	}
	if (!cudaError && cudaMemcpy(instanceSolution.bestScheduleOrder, cudaData.ordersOfSolutions+indexToTheBestSolution*cudaData.numberOfActivities,
				instance.numberOfActivities*sizeof(uint16_t), cudaMemcpyDeviceToHost) != cudaSuccess)	{
		cudaError = true;	
	}
	if (!cudaError && cudaMemcpy(&numberOfEvaluatedSchedules, cudaData.evaluatedSchedules, sizeof(uint64_t), cudaMemcpyDeviceToHost) != cudaSuccess)	{
		cudaError = true;	
	}

	if (cudaError == true)	{
		errorHandler(-2);
		delete[] instanceSolution.bestScheduleOrder;
		instanceSolution.bestScheduleOrder = NULL;
		throw runtime_error("ScheduleSolver::solveSchedule: Error occur when try to solve the instance!");
	}

	#ifdef __GNUC__
	gettimeofday(&endTime, NULL);
	timersub(&endTime, &startTime, &diffTime);
	totalRunTime += diffTime.tv_sec+diffTime.tv_usec/1000000.;
	#elif defined _WIN32 || defined _WIN64 || defined WIN32 || defined WIN64
	QueryPerformanceCounter(&stopTimeStamp);
	totalRunTime += (stopTimeStamp.QuadPart-startTimeStamp.QuadPart)/((double) ticksPerSecond.QuadPart);
	#endif
}

void ScheduleSolver::printBestSchedule(bool verbose, ostream& output)	{
	swap(instanceSolution.orderOfActivities, instanceSolution.bestScheduleOrder);
	printSchedule(instance, instanceSolution, totalRunTime, numberOfEvaluatedSchedules,  verbose, output);
	swap(instanceSolution.orderOfActivities, instanceSolution.bestScheduleOrder);
}

void ScheduleSolver::writeBestScheduleToFile(const string& fileName) {
	ofstream out(fileName.c_str(), ios::out | ios::binary | ios::trunc);
	if (!out)
		throw invalid_argument("ScheduleSolver::writeBestScheduleToFile: Cannot open the output file to write!");

	writeBestScheduleToFile(out, instance, instanceSolution).close();
}

	
ofstream& ScheduleSolver::writeBestScheduleToFile(ofstream& out, const InstanceData& project, const InstanceSolution& solution)	{
	/* WRITE INTANCE DATA */
	uint32_t numberOfActivitiesUint32 = project.numberOfActivities, numberOfResourcesUint32 = project.numberOfResources;
	out.write((const char*) &numberOfActivitiesUint32, sizeof(uint32_t));
	out.write((const char*) &numberOfResourcesUint32, sizeof(uint32_t));

	uint32_t *activitiesDurationUint32 = convertArrayType<uint8_t, uint32_t>(project.durationOfActivities, project.numberOfActivities);
	out.write((const char*) activitiesDurationUint32, project.numberOfActivities*sizeof(uint32_t));
	uint32_t *capacityOfResourcesUint32 = convertArrayType<uint8_t, uint32_t>(project.capacityOfResources, project.numberOfResources);
	out.write((const char*) capacityOfResourcesUint32, project.numberOfResources*sizeof(uint32_t));
	for (uint16_t i = 0; i < project.numberOfActivities; ++i)	{
		uint32_t *activityRequiredResourcesUint32 = convertArrayType<uint8_t, uint32_t>(project.requiredResourcesOfActivities[i], project.numberOfResources);
		out.write((const char*) activityRequiredResourcesUint32, project.numberOfResources*sizeof(uint32_t));
		delete[] activityRequiredResourcesUint32;
	}

	uint32_t *numberOfSuccessorsUint32 = convertArrayType<uint16_t, uint32_t>(project.numberOfSuccessors, project.numberOfActivities);
	out.write((const char*) numberOfSuccessorsUint32, project.numberOfActivities*sizeof(uint32_t));
	for (uint16_t i = 0; i < project.numberOfActivities; ++i)	{
		uint32_t *activitySuccessorsUint32 = convertArrayType<uint16_t, uint32_t>(project.successorsOfActivity[i], project.numberOfSuccessors[i]);
		out.write((const char*) activitySuccessorsUint32, project.numberOfSuccessors[i]*sizeof(uint32_t));
		delete[] activitySuccessorsUint32;
	}

	uint32_t *numberOfPredecessorsUint32 = convertArrayType<uint16_t, uint32_t>(project.numberOfPredecessors, project.numberOfActivities);
	out.write((const char*) numberOfPredecessorsUint32, project.numberOfActivities*sizeof(uint32_t));
	for (uint16_t i = 0; i < project.numberOfActivities; ++i)	{
		uint32_t *activityPredecessorsUint32 = convertArrayType<uint16_t, uint32_t>(project.predecessorsOfActivity[i], project.numberOfPredecessors[i]);
		out.write((const char*) activityPredecessorsUint32, project.numberOfPredecessors[i]*sizeof(uint32_t));
		delete[] activityPredecessorsUint32;
	}

	delete[] numberOfPredecessorsUint32;
	delete[] numberOfSuccessorsUint32;
	delete[] capacityOfResourcesUint32;
	delete[] activitiesDurationUint32;

	/* WRITE RESULTS */
	InstanceSolution copySolution = solution;
	uint16_t *startTimesById = new uint16_t[project.numberOfActivities];
	copySolution.orderOfActivities = new uint16_t[project.numberOfActivities];
	copy(solution.bestScheduleOrder, solution.bestScheduleOrder+project.numberOfActivities, copySolution.orderOfActivities);

	uint32_t scheduleLength = shakingDownEvaluation(project, solution, startTimesById);
	convertStartTimesById2ActivitiesOrder(project, copySolution, startTimesById);

	out.write((const char*) &scheduleLength, sizeof(uint32_t));
	uint32_t *copyOrderUint32 = convertArrayType<uint16_t, uint32_t>(copySolution.orderOfActivities, project.numberOfActivities);
	out.write((const char*) copyOrderUint32, project.numberOfActivities*sizeof(uint32_t));
	uint32_t *startTimesByIdUint32 = convertArrayType<uint16_t, uint32_t>(startTimesById, project.numberOfActivities);
	out.write((const char*) startTimesByIdUint32, project.numberOfActivities*sizeof(uint32_t));

	delete[] startTimesByIdUint32;
	delete[] copyOrderUint32;
	delete[] copySolution.orderOfActivities;
	delete[] startTimesById;

	return out;
}

uint16_t* ScheduleSolver::computeLowerBounds(const uint16_t& startActivityId, const InstanceData& project, const bool& energyReasoning) {
	// The first dummy activity is added to list.
	list<uint16_t> expandedNodes(1, startActivityId);
	// We have to remember closed activities. (the bound of the activity is determined)
	bool *closedActivities = new bool[project.numberOfActivities];
	fill(closedActivities, closedActivities+project.numberOfActivities, false);
	// The longest path from the start activity to the activity at index "i".
	uint16_t *maxDistances = new uint16_t[project.numberOfActivities];
	fill(maxDistances, maxDistances+project.numberOfActivities, 0);
	// All branches that go through nodes are saved.
	// branches[i][j] = p -> The p-nd branch that started in the node j goes through node i.
	int32_t ** branches = NULL;
	// An auxiliary array that stores all activities between the start activity and end activity.
	uint16_t *intersectionOfActivities = NULL;
	// An auxiliary array that stores the predecessors branches.
	int32_t **predecessorsBranches = NULL;
	// It allocates/initialises memory only if it is required.
	if (energyReasoning == true)	 {
		branches = new int32_t*[project.numberOfActivities];
		branches[startActivityId] = new int32_t[project.numberOfActivities];
		fill(branches[startActivityId], branches[startActivityId]+project.numberOfActivities, -1);
		for (uint16_t id = 0; id < project.numberOfActivities; ++id)	{
			if (id != startActivityId)
				branches[id] = NULL;
		}
		intersectionOfActivities = new uint16_t[project.numberOfActivities];
		predecessorsBranches = new int32_t*[project.numberOfActivities];
	}

	while (!expandedNodes.empty())	{
		uint16_t activityId;
		uint16_t minimalStartTime;
		// We select the first activity with all predecessors closed.
		list<uint16_t>::iterator lit = expandedNodes.begin();
		while (lit != expandedNodes.end())	{
			activityId = *lit;
			if (closedActivities[activityId] == false)	{
				minimalStartTime = 0;
				bool allPredecessorsClosed = true;
				for (uint16_t p = 0; p < project.numberOfPredecessors[activityId]; ++p)	{
					uint16_t predecessor = project.predecessorsOfActivity[activityId][p];
					if (closedActivities[predecessor] == false)	{
						allPredecessorsClosed = false;
						break;
					} else {
						// It updates the maximal distance from the start activity to the activity "activityId".
						minimalStartTime = max((uint16_t) (maxDistances[predecessor]+project.durationOfActivities[predecessor]), minimalStartTime);
						if (project.numberOfPredecessors[activityId] > 1 && energyReasoning)
							predecessorsBranches[p] = branches[predecessor];
					}
				}
				if (allPredecessorsClosed)	{
					if (project.numberOfPredecessors[activityId] > 1 && energyReasoning) {
						// Output branches are found out for the node with more predecessors.
						set<uint16_t> startNodesOfMultiPaths;
						branches[activityId] = new int32_t[project.numberOfActivities];
						fill(branches[activityId], branches[activityId]+project.numberOfActivities, -1);
						for (uint16_t p = 0; p < project.numberOfPredecessors[activityId]; ++p)	{
							int32_t * activityGoThroughBranches = predecessorsBranches[p];
							for (uint16_t id = 0; id < project.numberOfActivities; ++id)	{
								if (branches[activityId][id] == -1)	{
									branches[activityId][id] = activityGoThroughBranches[id];
								} else if (activityGoThroughBranches[id] != -1) {
									// The branch number has to be checked.
									if (activityGoThroughBranches[id] != branches[activityId][id])	{
										// Multi-paths were detected! New start node is stored.
										startNodesOfMultiPaths.insert(id);
									}
								}
							}
						}
						// If more than one path exists to the node "activityId", then the resource restrictions
						// are taken into accout to improve lower bound.
						uint16_t minimalResourceStartTime = 0;
						for (set<uint16_t>::const_iterator sit = startNodesOfMultiPaths.begin(); sit != startNodesOfMultiPaths.end(); ++sit)	{
							// Vectors are sorted by activity id's.
							vector<uint16_t>* allSuccessors = project.allSuccessorsCache[*sit];
							vector<uint16_t>* allPredecessors = project.allPredecessorsCache[activityId];
							// The array of all activities between activity "i" and activity "j".
							uint16_t *intersectionEndPointer = set_intersection(allPredecessors->begin(), allPredecessors->end(),
									allSuccessors->begin(), allSuccessors->end(), intersectionOfActivities);
							for (uint8_t k = 0; k < project.numberOfResources; ++k)	{
								uint32_t sumOfEnergy = 0, timeInterval;
								for (uint16_t *id = intersectionOfActivities; id < intersectionEndPointer; ++id)	{
									uint16_t innerActivityId = *id;
									sumOfEnergy += project.durationOfActivities[innerActivityId]*project.requiredResourcesOfActivities[innerActivityId][k];
								}

								timeInterval = sumOfEnergy/project.capacityOfResources[k];
								if ((sumOfEnergy % project.capacityOfResources[k]) != 0)
									++timeInterval;
								
								minimalResourceStartTime = max((uint32_t) minimalResourceStartTime, maxDistances[*sit]+project.durationOfActivities[*sit]+timeInterval); 
							}
						}
						minimalStartTime = max(minimalStartTime, minimalResourceStartTime);
					}
					break;
				}

				++lit;
			} else {
				lit = expandedNodes.erase(lit);
			}
		}
		
		if (lit != expandedNodes.end())	{
			// The successors of the current activity are added.
			uint16_t numberOfSuccessorsOfClosedActivity = project.numberOfSuccessors[activityId];
			for (uint16_t s = 0; s < numberOfSuccessorsOfClosedActivity; ++s)	{
				uint16_t successorId = project.successorsOfActivity[activityId][s];
				if (project.numberOfPredecessors[successorId] <= 1 && energyReasoning)	{
					branches[successorId] = new int32_t[project.numberOfActivities];
					if (branches[activityId] == NULL)	{
						fill(branches[successorId], branches[successorId], -1);
					} else	{
						copy(branches[activityId], branches[activityId]+project.numberOfActivities, branches[successorId]);
					}

					if (numberOfSuccessorsOfClosedActivity > 1)	{
						branches[successorId][activityId] = s;
					}
				}
				expandedNodes.push_back(successorId);
			}

			// The proccessed activity is closed and its distance from the start activity is updated.
			closedActivities[activityId] = true;
			maxDistances[activityId] = minimalStartTime;
			// It erases a proccessed activity from the list.
			expandedNodes.erase(lit);
		} else {
			break;
		}
	}

	// It frees all allocated memory.
	if (energyReasoning == true)	{
		delete[] predecessorsBranches;
		delete[] intersectionOfActivities;
		for (uint16_t i = 0; i < project.numberOfActivities; ++i)
			delete[] branches[i];
		delete[] branches;
	}
	delete[] closedActivities; 

	return maxDistances;
}

uint16_t ScheduleSolver::lowerBoundOfMakespan(const InstanceData& project) {
	// It creates the list of activities.
	vector<ListActivity> listOfActivities;
	for (uint16_t i = 0; i < project.numberOfActivities; ++i)	{
		uint16_t concurrencyLevel = 0;
		for (uint16_t j = 0; j < project.numberOfActivities; ++j)	{
			if (i != j && project.disjunctiveActivities[i][j] == false)
				++concurrencyLevel;
		}
		listOfActivities.push_back(ListActivity(i, concurrencyLevel, project.durationOfActivities[i]));
	}
	
	// A sorting heuristic is applied to the list.
	sort(listOfActivities.begin(), listOfActivities.end());

	InstanceData copyOfProject = project;
	uint16_t maximalLowerBound = 0, lowerBound = 0;
	copyOfProject.durationOfActivities = new uint8_t[project.numberOfActivities];
	copy(project.durationOfActivities, project.durationOfActivities+project.numberOfActivities, copyOfProject.durationOfActivities);
	for (uint16_t i = 0; i < copyOfProject.numberOfActivities; ++i)	{
		// It creates the new subset of the unprocessed activities.
		uint16_t activityId1 = listOfActivities[i].activityId, subsetDuration = listOfActivities[i].duration;
		if (subsetDuration > 0)	{
			// It computes an estimate of the lower and upper bounds.
			uint16_t *lb = computeLowerBounds(0, copyOfProject, true);
	 		changeDirectionOfEdges(copyOfProject);
	 		uint16_t *ub = computeLowerBounds(copyOfProject.numberOfActivities-1, copyOfProject, true);
	 		changeDirectionOfEdges(copyOfProject);
			maximalLowerBound = max(maximalLowerBound, (uint16_t) (lowerBound+max(lb[copyOfProject.numberOfActivities-1], ub[0])));
			delete[] lb; delete[] ub;

			// All activities which are able to run concurrently with activity "activityId1" have reduced duration.
			for (uint16_t j = i+1; j < copyOfProject.numberOfActivities; ++j)	{
				uint8_t durationJ = listOfActivities[j].duration;
				uint16_t activityId2 = listOfActivities[j].activityId;
				if (project.disjunctiveActivities[activityId1][activityId2] == false && durationJ > 0)
					copyOfProject.durationOfActivities[activityId2] = listOfActivities[j].duration = ((durationJ > subsetDuration) ? durationJ-subsetDuration : 0);
			}

			// Remove the selected activity from the list.
			copyOfProject.durationOfActivities[activityId1] = listOfActivities[i].duration = 0;
			lowerBound += subsetDuration;
		}
	}
	maximalLowerBound = max(maximalLowerBound, lowerBound);

	delete[] copyOfProject.durationOfActivities;

	return maximalLowerBound;
}


uint16_t ScheduleSolver::evaluateOrder(const InstanceData& project, const InstanceSolution& solution, uint16_t *& timeValuesById, bool forwardEvaluation)	{
	uint16_t scheduleLength = 0;
	SourcesLoad sourcesLoad(project.numberOfResources, project.capacityOfResources, project.upperBoundMakespan);
	for (uint16_t i = 0; i < project.numberOfActivities; ++i)	{
		uint16_t start = 0;
		uint16_t activityId = solution.orderOfActivities[forwardEvaluation == true ? i : project.numberOfActivities-i-1];
		for (uint16_t j = 0; j < project.numberOfPredecessors[activityId]; ++j)	{
			uint16_t predecessorActivityId = project.predecessorsOfActivity[activityId][j];
			start = max((uint16_t) (timeValuesById[predecessorActivityId]+project.durationOfActivities[predecessorActivityId]), start);
		}

		start = max(sourcesLoad.getEarliestStartTime(project.requiredResourcesOfActivities[activityId], start, project.durationOfActivities[activityId]), start);
		sourcesLoad.addActivity(start, start+project.durationOfActivities[activityId], project.requiredResourcesOfActivities[activityId]);
		scheduleLength = max(scheduleLength, (uint16_t) (start+project.durationOfActivities[activityId]));

		timeValuesById[activityId] = start;
	}

	return scheduleLength;
}

uint16_t ScheduleSolver::forwardScheduleEvaluation(const InstanceData& project, const InstanceSolution& solution, uint16_t *& startTimesById) {
	return evaluateOrder(project, solution, startTimesById, true);
}

uint16_t ScheduleSolver::backwardScheduleEvaluation(const InstanceData& project, const InstanceSolution& solution, uint16_t *& startTimesById) {
	InstanceData copyProject = project;
	changeDirectionOfEdges(copyProject);
	uint16_t makespan = evaluateOrder(copyProject, solution, startTimesById, false);
	// It computes the latest start time value for each activity.
	for (uint16_t id = 0; id < copyProject.numberOfActivities; ++id)
		startTimesById[id] = makespan-startTimesById[id]-copyProject.durationOfActivities[id];
	return makespan;
}

uint16_t ScheduleSolver::shakingDownEvaluation(const InstanceData& project, const InstanceSolution& solution, uint16_t *bestScheduleStartTimesById)	{
	uint16_t scheduleLength = 0;
	uint16_t bestScheduleLength = USHRT_MAX;
	uint16_t *currentOrder = new uint16_t[project.numberOfActivities];
	uint16_t *timeValuesById = new uint16_t[project.numberOfActivities];
	InstanceSolution copySolution = solution;
	copy(solution.orderOfActivities, solution.orderOfActivities+project.numberOfActivities, currentOrder);
	copySolution.orderOfActivities = currentOrder;

	while (true)	{
		// Forward schedule...
		scheduleLength = forwardScheduleEvaluation(project, copySolution, timeValuesById);
		if (scheduleLength < bestScheduleLength)	{
			bestScheduleLength = scheduleLength;
			if (bestScheduleStartTimesById != NULL)	{
				for (uint16_t id = 0; id < project.numberOfActivities; ++id)
					bestScheduleStartTimesById[id] = timeValuesById[id];
			}
		} else	{
			// No additional improvement can be found...
			break;
		}

		// It computes the earliest activities finish time.
		for (uint16_t id = 0; id < project.numberOfActivities; ++id)
			timeValuesById[id] += project.durationOfActivities[id];

		// Sort for backward phase..
		insertSort(project, copySolution, timeValuesById);

		// Backward phase.
		uint16_t scheduleLengthBackward = backwardScheduleEvaluation(project, copySolution, timeValuesById);
		int16_t diffCmax = scheduleLength-scheduleLengthBackward;

		// It computes the latest start time of activities.
		for (uint16_t id = 0; id < project.numberOfActivities; ++id)	{
			if (timeValuesById[id]+diffCmax > 0)
				timeValuesById[id] += diffCmax;
			else
				timeValuesById[id] = 0;
		}

		// Sort for forward phase..
		insertSort(project, copySolution, timeValuesById);
	}

	delete[] copySolution.orderOfActivities;
	delete[] timeValuesById;

	return bestScheduleLength;
}

uint16_t ScheduleSolver::computePrecedencePenalty(const InstanceData& project, const uint16_t * const& startTimesById)	{
	uint16_t penalty = 0;
	for (uint16_t activityId = 0; activityId < project.numberOfActivities; ++activityId)	{
		for (uint16_t j = 0; j < project.numberOfSuccessors[activityId]; ++j)	{
			uint16_t successorId = project.successorsOfActivity[activityId][j];	
			if (startTimesById[activityId]+project.durationOfActivities[activityId] > startTimesById[successorId])
				penalty += startTimesById[activityId]+project.durationOfActivities[activityId]-startTimesById[successorId];
		}
	}
	return penalty;
}

bool ScheduleSolver::checkSwapPrecedencePenalty(const InstanceData& project, const InstanceSolution& solution, uint16_t i, uint16_t j)	{
	if (i > j) swap(i,j);
	for (uint16_t k = i; k < j; ++k)	{
		if (project.matrixOfSuccessors[solution.orderOfActivities[k]][solution.orderOfActivities[j]] == 1)	{
			return false;
		}
	}
	for (uint16_t k = i+1; k <= j; ++k)	{
		if (project.matrixOfSuccessors[solution.orderOfActivities[i]][solution.orderOfActivities[k]] == 1)	{
			return false;
		}
	}
	return true;
}

void ScheduleSolver::printSchedule(const InstanceData& project, const InstanceSolution& solution, double runTime, uint64_t evaluatedSchedules, bool verbose, ostream& output)	{
	if (solution.orderOfActivities)	{
		uint16_t *startTimesById = new uint16_t[project.numberOfActivities];
		uint16_t scheduleLength = shakingDownEvaluation(project, solution, startTimesById);
		uint16_t precedencePenalty = computePrecedencePenalty(project, startTimesById);
	
		if (verbose == true)	{
			output<<"start\tactivities"<<endl;
			for (uint16_t c = 0; c <= scheduleLength; ++c)	{
				bool first = true;
				for (uint16_t id = 0; id < project.numberOfActivities; ++id)	{
					if (startTimesById[id] == c)	{
						if (first == true)	{
							output<<c<<":\t"<<id;
							first = false;
						} else {
							output<<" "<<id;
						}
					}
				}
				if (!first)	output<<endl;
			}
			output<<"Schedule length: "<<scheduleLength<<endl;
			output<<"Precedence penalty: "<<precedencePenalty<<endl;
			output<<"Critical path makespan: "<<project.criticalPathMakespan<<endl;
			output<<"Schedule solve time: "<<runTime<<" s"<<endl;
			output<<"Total number of evaluated schedules: "<<evaluatedSchedules<<endl;
		}	else	{
			output<<scheduleLength<<"+"<<precedencePenalty<<" "<<project.criticalPathMakespan<<"\t["<<runTime<<" s]\t"<<evaluatedSchedules<<endl;
		} 
		delete[] startTimesById;
	} else {
		output<<"Solution hasn't been computed yet!"<<endl;
	}
}

void ScheduleSolver::convertStartTimesById2ActivitiesOrder(const InstanceData& project, InstanceSolution& solution, const uint16_t * const& startTimesById) {
	insertSort(project, solution, startTimesById);
}

void ScheduleSolver::insertSort(const InstanceData& project, InstanceSolution& solution, const uint16_t * const& timeValuesById) {
	for (uint16_t i = 1; i < project.numberOfActivities; ++i)	{
		for (int16_t j = i; (j > 0) && ((timeValuesById[solution.orderOfActivities[j]] < timeValuesById[solution.orderOfActivities[j-1]]) == true); --j)	{
			swap(solution.orderOfActivities[j], solution.orderOfActivities[j-1]);
		}
	}
}

void ScheduleSolver::makeDiversification(const InstanceData& project, InstanceSolution& solution)	{
	uint32_t performedSwaps = 0;
	while (performedSwaps < ConfigureRCPSP::DIVERSIFICATION_SWAPS)	{
		uint16_t i = (rand() % (project.numberOfActivities-2)) + 1;
		uint16_t j = (rand() % (project.numberOfActivities-2)) + 1;

		if ((i != j) && (checkSwapPrecedencePenalty(project, solution, i, j) == true))	{
			swap(solution.orderOfActivities[i], solution.orderOfActivities[j]);
			++performedSwaps;
		}
	}
}

void ScheduleSolver::changeDirectionOfEdges(InstanceData& project)	{
	swap(project.numberOfSuccessors, project.numberOfPredecessors);
	swap(project.successorsOfActivity, project.predecessorsOfActivity);
	for (uint16_t i = 0; i < project.numberOfActivities; ++i)
		swap(project.allSuccessorsCache[i], project.allPredecessorsCache[i]);
}

vector<uint16_t>* ScheduleSolver::getAllRelatedActivities(uint16_t activityId, uint16_t *numberOfRelated, uint16_t **related, uint16_t numberOfActivities) {
	vector<uint16_t>* relatedActivities = new vector<uint16_t>();
	bool *activitiesSet = new bool[numberOfActivities];
	fill(activitiesSet, activitiesSet+numberOfActivities, false);

	for (uint16_t j = 0; j < numberOfRelated[activityId]; ++j)	{
		activitiesSet[related[activityId][j]] = true;
		vector<uint16_t>* indirectRelated = getAllRelatedActivities(related[activityId][j], numberOfRelated, related, numberOfActivities);
		for (vector<uint16_t>::const_iterator it = indirectRelated->begin(); it != indirectRelated->end(); ++it)
			activitiesSet[*it] = true;
		delete indirectRelated;
	}

	for (uint16_t id = 0; id < numberOfActivities; ++id)	{
		if (activitiesSet[id] == true)
			relatedActivities->push_back(id);
	}
	
	delete[] activitiesSet;
	return relatedActivities;
}

vector<uint16_t>* ScheduleSolver::getAllActivitySuccessors(const uint16_t& activityId, const InstanceData& project) {
	return getAllRelatedActivities(activityId, project.numberOfSuccessors, project.successorsOfActivity, project.numberOfActivities);
}

vector<uint16_t>* ScheduleSolver::getAllActivityPredecessors(const uint16_t& activityId, const InstanceData& project) {
	return getAllRelatedActivities(activityId, project.numberOfPredecessors, project.predecessorsOfActivity, project.numberOfActivities);
}

template <class X, class Y>
Y* ScheduleSolver::convertArrayType(X* array, size_t length)	{
	Y* convertedArray = new Y[length];
	for (uint32_t i = 0; i < length; ++i)
		convertedArray[i] = array[i];
	return convertedArray;
}

ScheduleSolver::~ScheduleSolver()	{
	// Free all allocated cuda memory.
	errorHandler(-1);
	cudaDeviceReset();
	// Free all allocated host memory.
	for (uint16_t actId = 0; actId < instance.numberOfActivities; ++actId)	{
		delete[] instance.predecessorsOfActivity[actId];
		delete[] instance.matrixOfSuccessors[actId];
		delete instance.allSuccessorsCache[actId];
		delete instance.allPredecessorsCache[actId];
		delete[] instance.disjunctiveActivities[actId];
	}
	delete[] instance.predecessorsOfActivity;
	delete[] instance.numberOfPredecessors;
	delete[] instance.matrixOfSuccessors;
	delete[] instance.rightLeftLongestPaths;
	delete[] instance.disjunctiveActivities;
	delete[] instanceSolution.orderOfActivities;
	delete[] instanceSolution.bestScheduleOrder;
}

template <class T>
T* ScheduleSolver::copyAndPush(T* array, uint32_t size, T value)	{
	uint16_t *newArray = new uint16_t[size+1];
	copy(array, array+size, newArray);
	newArray[size] = value;
	return newArray;
}

