#include "voxelinformationtool.h"
#include "q2dviewer.h"
#include "volume.h"
#include "drawertext.h"
#include "drawer.h"
#include "voxel.h"
#include "logging.h"
// Vtk
#include <vtkCommand.h>

namespace udg {

VoxelInformationTool::VoxelInformationTool(QViewer *viewer, QObject *parent)
 : Tool(viewer, parent), m_caption(0)
{
    m_toolName = "VoxelInformationTool";

    m_2DViewer = Q2DViewer::castFromQViewer(viewer);
    createCaption();
    connect(m_2DViewer, SIGNAL(sliceChanged(int)), SLOT(updateCaption()));
    connect(m_2DViewer, SIGNAL(phaseChanged(int)), SLOT(updateCaption()));
    connect(m_2DViewer, SIGNAL(cameraChanged()), SLOT(updateCaption()));
}

VoxelInformationTool::~VoxelInformationTool()
{
    if (m_caption)
    {
        // Així alliberem la primitiva perquè pugui ser esborrada
        m_caption->decreaseReferenceCount();
        delete m_caption;
    }
}

void VoxelInformationTool::handleEvent(unsigned long eventID)
{
    switch (eventID)
    {
        case vtkCommand::MouseMoveEvent:
            updateCaption();
            break;

        case vtkCommand::EnterEvent:
            break;

        case vtkCommand::LeaveEvent:
            m_caption->visibilityOff();
            m_caption->update();
            m_2DViewer->render();
            break;

        default:
            break;
    }
}

void VoxelInformationTool::createCaption()
{
    if (!m_caption)
    {
        m_caption = new DrawerText;
        // Així evitem que durant l'ús de l'eina la primitiva pugui ser esborrada per events externs
        m_caption->increaseReferenceCount();
        // Inicialment serà invisible
        m_caption->visibilityOff();
        m_2DViewer->getDrawer()->draw(m_caption);
    }
}

void VoxelInformationTool::updateCaption()
{
    if (!m_caption)
    {
        return;
    }

    double xyz[3];
    if (m_2DViewer->getCurrentCursorImageCoordinate(xyz))
    {
        double attachmentPoint[3];
        QString horizontalJustification, verticalJustification;
        computeCaptionAttachmentPointAndTextAlignment(attachmentPoint, horizontalJustification, verticalJustification);

        // Actualitzem els valors del caption
        m_caption->visibilityOn();
        m_caption->setAttachmentPoint(attachmentPoint);
        m_caption->setHorizontalJustification(horizontalJustification);
        m_caption->setVerticalJustification(verticalJustification);
        m_caption->setText(computeVoxelValue(xyz));
        m_caption->update();
    }
    else
    {
        m_caption->visibilityOff();
        m_caption->update();
    }
    m_2DViewer->render();
}

QString VoxelInformationTool::computeVoxelValue(double worldCoordinate[3])
{
    Voxel voxel;
    VolumePixelData *pixelData = m_2DViewer->getCurrentPixelData();
    int phaseIndex = 0;
    int numberOfPhases = 1;
    
    if (!m_2DViewer->isThickSlabActive() && m_2DViewer->getView() == OrthogonalPlane::XYPlane && m_2DViewer->getInput()->getNumberOfPhases() > 1)
    {
        numberOfPhases = m_2DViewer->getInput()->getNumberOfPhases();
        phaseIndex = m_2DViewer->getCurrentPhase();
    }

    pixelData->getVoxelValue(worldCoordinate, voxel, phaseIndex, numberOfPhases);

    return voxel.getAsQString();
}

void VoxelInformationTool::computeCaptionAttachmentPointAndTextAlignment(double attachmentPoint[3], QString &horizontalJustification,
                                                                         QString &verticalJustification)
{
    // Per defecte alinearem el texte a la dreta i el més amunt possible
    horizontalJustification = "Right";
    verticalJustification = "Top";
    // Amb aquest valor definim el marge fins on considerem estar prou a prop d'alguna de les cantonades del visor
    int marginPixels = 50;
    // Calculem les mides del viewport per saber on tenim col·locat el cursor
    QSize viewportSize = m_2DViewer->getRenderWindowSize();
    QPoint cursorPosition = m_2DViewer->getEventPosition();

    // Aquestes seran les coordenades que ajustarem per col·locar el caption
    QPoint adjustedCursorPosition = cursorPosition;

    bool insideMargins = true;
    // Estem quasi a dalt de tot?
    if (cursorPosition.y() > viewportSize.height() - marginPixels)
    {
        adjustedCursorPosition.setY(viewportSize.height() - marginPixels);
        verticalJustification = "Bottom";
        insideMargins = false;
    }

    // Estem quasi abaix del tot?
    if (cursorPosition.y() < marginPixels)
    {
        adjustedCursorPosition.setY(marginPixels);
        verticalJustification = "Top";
        insideMargins = false;
    }

    // Estem a prop de la dreta?
    if (cursorPosition.x() > viewportSize.width() - marginPixels)
    {
        adjustedCursorPosition.setX(viewportSize.width() - marginPixels);
        horizontalJustification = "Right";
        insideMargins = false;
    }

    // Estem a prop de l'esquerra?
    if (cursorPosition.x() < marginPixels)
    {
        adjustedCursorPosition.setX(marginPixels);
        horizontalJustification = "Left";
        insideMargins = false;
    }

    if (insideMargins)
    {
        adjustedCursorPosition.rx() -= 5;
        adjustedCursorPosition.ry() += 5;
    }

    // I finalment transformem la coordenada de viewport en coordenada de món
    m_2DViewer->computeDisplayToWorld(adjustedCursorPosition.x(), adjustedCursorPosition.y(), 0.0, attachmentPoint);
}

}
